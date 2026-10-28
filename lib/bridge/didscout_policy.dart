import 'package:obdbridge/obdbridge.dart';

/// didscout's own [CommandPolicy], layered under [HardGuard] (which still
/// rejects VIN/serial reads and any non-read service regardless of this
/// policy). Deliberately narrower than [HardGuard]'s own allow-list:
///
/// - adapter setup/identification commands only,
/// - protocol selection restricted to 6 (11-bit CAN) and 7 (29-bit CAN),
/// - headers restricted to the 11-bit physical range `0x700`-`0x7EF`, the
///   29-bit physical pattern `18DAxxF1`/`18DAF1xx`, and the functional
///   broadcast headers `7DF`/`18DB33F1`,
/// - mode 01 reads and UDS ReadDataByIdentifier (`22`) reads.
class DidscoutPolicy implements CommandPolicy {
  static final RegExp _hex = RegExp(r'^[0-9A-F]+$');
  static final RegExp _headerCommand = RegExp(
    r'^(ATSH|ATCRA|ATFCSH)([0-9A-F]+)$',
  );
  static final RegExp _elevenBitPhysical = RegExp(r'^7[0-9A-F]{2}$');
  static final RegExp _twentyNineBitPhysicalRequest = RegExp(
    r'^18DA[0-9A-F]{2}F1$',
  );
  static final RegExp _twentyNineBitPhysicalResponse = RegExp(
    r'^18DAF1[0-9A-F]{2}$',
  );

  static const Set<String> _allowedAdapterCommands = {
    // Setup.
    'ATZ', 'ATE0', 'ATE1', 'ATL0', 'ATL1', 'ATS0', 'ATS1', 'ATH0', 'ATH1',
    // Identification.
    'ATI', 'ATRV', 'ATDP', 'ATDPN', 'STI', 'STDI',
    // Flow control, fixed to the exact shape buildModuleSetupCommands emits.
    'ATFCSD300000', 'ATFCSM1',
    // Receive filter/mask for the 11-bit manufacturer-ECU discovery sweep:
    // accepts a reply from any header in 0x700-0x7FF, since the ECU that
    // answers a given request header is not known in advance.
    'ATCF700', 'ATCM700',
  };

  static const Set<String> _allowedProtocolSelectCommands = {'ATSP6', 'ATSP7'};

  static const Set<String> _allowedFunctionalHeaders = {'7DF', '18DB33F1'};

  @override
  bool allows(String normalizedCommand) {
    if (normalizedCommand.startsWith('AT') ||
        normalizedCommand.startsWith('ST')) {
      return _allowsAdapterCommand(normalizedCommand);
    }
    if (!_hex.hasMatch(normalizedCommand) ||
        normalizedCommand.length % 2 != 0) {
      return false;
    }
    final service = normalizedCommand.substring(0, 2);
    switch (service) {
      case '01':
        return normalizedCommand.length == 4;
      case '22':
        return normalizedCommand.length == 6;
      default:
        return false;
    }
  }

  static bool _allowsAdapterCommand(String normalized) {
    if (_allowedAdapterCommands.contains(normalized) ||
        _allowedProtocolSelectCommands.contains(normalized)) {
      return true;
    }
    final headerMatch = _headerCommand.firstMatch(normalized);
    if (headerMatch != null) {
      return _isAllowedHeader(headerMatch.group(2)!);
    }
    return false;
  }

  static bool _isAllowedHeader(String header) {
    if (_allowedFunctionalHeaders.contains(header)) {
      return true;
    }
    if (header.length == 3) {
      if (!_elevenBitPhysical.hasMatch(header)) {
        return false;
      }
      final value = int.parse(header, radix: 16);
      return value >= 0x700 && value <= 0x7EF;
    }
    if (header.length == 8) {
      return _twentyNineBitPhysicalRequest.hasMatch(header) ||
          _twentyNineBitPhysicalResponse.hasMatch(header);
    }
    return false;
  }
}
