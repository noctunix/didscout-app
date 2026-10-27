import 'dart:typed_data';

/// The result of reassembling the explicit CAN ISO-TP frames in one
/// exchange's response text: the complete payloads recovered, keyed by the
/// responder header that sent them, plus whether any frame was malformed and
/// which headers opened a multi-frame reply that never completed.
class IsotpParseResult {
  final List<IsotpMessage> messages;
  final bool malformed;
  final bool incomplete;
  final Set<String> partialHeaders;

  const IsotpParseResult({
    required this.messages,
    required this.malformed,
    required this.incomplete,
    required this.partialHeaders,
  });
}

/// One reassembled ISO-TP payload, tagged with the header of the responder
/// that sent it.
class IsotpMessage {
  final String header;
  final Uint8List data;

  const IsotpMessage(this.header, this.data);
}

final RegExp _hexOnly = RegExp(r'^[0-9A-F]+$');
final RegExp _whitespace = RegExp(r'\s+');

/// Reassembles the explicit CAN ISO-TP frames in [response] (the text an
/// adapter returned for [command]), retaining each payload's responder
/// header. Ported line-for-line from `didscout.py`'s `parse_isotp`: a line is
/// either the echoed command or "SEARCHING...", pure hex, or malformed; the
/// header is the first 3 hex digits for an 11-bit (even-length) frame or the
/// first 8 for a 29-bit (odd-length) one; the nibble above the header's data
/// byte marks a single frame (0), first frame (1), or consecutive frame (2).
IsotpParseResult parseIsotp(String command, String response) {
  final text = response.toUpperCase();
  final messages = <IsotpMessage>[];
  // header -> (total size, payload so far, next expected sequence number)
  final partial = <String, (int, List<int>, int)>{};
  var malformed = false;
  for (final line in text.split('\n')) {
    final flat = line.replaceAll(_whitespace, '');
    if (flat.isEmpty || flat == command || flat == 'SEARCHING...') continue;
    if (!_hexOnly.hasMatch(flat)) {
      malformed = true;
      continue;
    }
    final headerLen = flat.length.isOdd ? 3 : 8;
    if (flat.length < headerLen) {
      malformed = true;
      continue;
    }
    final header = flat.substring(0, headerLen);
    final body = flat.substring(headerLen);
    final headerValue = int.parse(header, radix: 16);
    final maxHeader = headerLen == 3 ? 0x7FF : 0x1FFFFFFF;
    if (body.isEmpty || body.length.isOdd || headerValue > maxHeader) {
      malformed = true;
      continue;
    }
    final data = _hexToBytes(body);
    if (data.length > 8) {
      malformed = true;
      continue;
    }
    final kind = data[0] >> 4;
    if (kind == 0) {
      final size = data[0] & 0xF;
      if (size < 1 ||
          size > 7 ||
          data.length < size + 1 ||
          partial.containsKey(header)) {
        malformed = true;
      } else {
        messages.add(
          IsotpMessage(header, Uint8List.fromList(data.sublist(1, size + 1))),
        );
      }
    } else if (kind == 1 && data.length == 8) {
      final size = ((data[0] & 0xF) << 8) | data[1];
      if (size <= 7 || partial.containsKey(header)) {
        malformed = true;
      } else {
        partial[header] = (size, data.sublist(2), 1);
      }
    } else if (kind == 2 && partial.containsKey(header)) {
      final (size, payload, sequence) = partial[header]!;
      if ((data[0] & 0xF) != sequence || data.length < 2) {
        malformed = true;
        continue;
      }
      final extended = [...payload, ...data.sublist(1)];
      if (extended.length >= size) {
        messages.add(
          IsotpMessage(header, Uint8List.fromList(extended.sublist(0, size))),
        );
        partial.remove(header);
      } else {
        partial[header] = (size, extended, (sequence + 1) % 16);
      }
    } else {
      malformed = true;
    }
  }
  return IsotpParseResult(
    messages: messages,
    malformed: malformed,
    incomplete: partial.isNotEmpty,
    partialHeaders: partial.keys.toSet(),
  );
}

List<int> _hexToBytes(String hex) {
  final bytes = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return bytes;
}

/// Whether [header] matches [pattern], where an `X` in [pattern] matches any
/// hex digit at that position. Both must be the same length.
bool responderMatches(String header, String pattern) {
  if (header.length != pattern.length) return false;
  for (var i = 0; i < header.length; i++) {
    if (pattern[i] != 'X' && pattern[i] != header[i]) return false;
  }
  return true;
}

/// Returns the data bytes of a positive reply to [command] from one
/// responder, or `null` if no matching positive response was found.
/// [responder] may be `null` for a single-responder exchange with no known
/// response header, in which case the first matching message is taken
/// regardless of its header.
Uint8List? decodePositivePayload(
  String command,
  String response,
  String? responder,
) {
  final expected = _hexToBytes(command.toUpperCase());
  final prefix = [expected[0] + 0x40, ...expected.sublist(1)];
  for (final message in parseIsotp(command, response).messages) {
    if (responder != null && !responderMatches(message.header, responder)) {
      continue;
    }
    if (_startsWith(message.data, prefix)) {
      return Uint8List.fromList(message.data.sublist(prefix.length));
    }
  }
  return null;
}

bool _startsWith(Uint8List data, List<int> prefix) {
  if (data.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (data[i] != prefix[i]) return false;
  }
  return true;
}

/// Convenience wrapper over [decodePositivePayload] for a UDS
/// ReadDataByIdentifier exchange: builds the `22`-prefixed command for [did]
/// (a 4-hex-digit identifier) and extracts the matching `0x62` positive
/// payload from [response].
Uint8List? readDataByIdentifierPayload(
  String did,
  String response, {
  String? responder,
}) {
  return decodePositivePayload('22${did.toUpperCase()}', response, responder);
}
