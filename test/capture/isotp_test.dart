import 'package:didscout_app/capture/isotp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseIsotp', () {
    test('reassembles an 11-bit single frame', () {
      final result = parseIsotp('22F40C', '7E8 04 62 F4 0C 2A');

      expect(result.malformed, isFalse);
      expect(result.incomplete, isFalse);
      expect(result.messages, hasLength(1));
      expect(result.messages.single.header, '7E8');
      expect(result.messages.single.data, [0x62, 0xF4, 0x0C, 0x2A]);
    });

    test('reassembles an 11-bit first frame plus consecutive frames', () {
      // Total payload length 10: first frame carries 6 bytes, one
      // consecutive frame carries the remaining 4.
      final response = [
        '7E8 10 0A 62 F4 0C 01 02 03',
        '7E8 21 04 05 06 07 08',
      ].join('\n');

      final result = parseIsotp('22F40C', response);

      expect(result.malformed, isFalse);
      expect(result.incomplete, isFalse);
      expect(result.messages, hasLength(1));
      expect(result.messages.single.header, '7E8');
      expect(result.messages.single.data, [
        0x62,
        0xF4,
        0x0C,
        0x01,
        0x02,
        0x03,
        0x04,
        0x05,
        0x06,
        0x07,
      ]);
    });

    test('reassembles a 29-bit (8-hex header) single frame', () {
      final result = parseIsotp('22F40C', '18DAF101 04 62 F4 0C 2A');

      expect(result.malformed, isFalse);
      expect(result.messages, hasLength(1));
      expect(result.messages.single.header, '18DAF101');
      expect(result.messages.single.data, [0x62, 0xF4, 0x0C, 0x2A]);
    });

    test('flags an unterminated multi-frame reply as incomplete', () {
      final result = parseIsotp('22F40C', '7E8 10 0A 62 F4 0C 01 02 03');

      expect(result.incomplete, isTrue);
      expect(result.partialHeaders, {'7E8'});
      expect(result.messages, isEmpty);
    });

    test('flags non-hex garbage as malformed without throwing', () {
      final result = parseIsotp('22F40C', 'NOT HEX AT ALL');

      expect(result.malformed, isTrue);
      expect(result.messages, isEmpty);
    });

    test('ignores the echoed command and SEARCHING banner', () {
      final response = [
        '22F40C',
        'SEARCHING...',
        '7E8 04 62 F4 0C 2A',
      ].join('\n');

      final result = parseIsotp('22F40C', response);

      expect(result.malformed, isFalse);
      expect(result.messages, hasLength(1));
    });
  });

  group('decodePositivePayload', () {
    test('extracts the data bytes of a matching positive 0x62 reply', () {
      final payload = decodePositivePayload(
        '22F40C',
        '7E8 04 62 F4 0C 2A',
        '7E8',
      );

      expect(payload, [0x2A]);
    });

    test('returns null when no positive reply matches', () {
      final payload = decodePositivePayload('22F40C', '7E8 03 7F 22 31', '7E8');

      expect(payload, isNull);
    });

    test('ignores a responder that does not match the pattern', () {
      final payload = decodePositivePayload(
        '22F40C',
        '7E9 04 62 F4 0C 2A',
        '7E8',
      );

      expect(payload, isNull);
    });

    test('matches a wildcarded responder pattern', () {
      final payload = decodePositivePayload(
        '22F40C',
        '7E8 04 62 F4 0C 2A',
        '7EX',
      );

      expect(payload, [0x2A]);
    });
  });

  group('readDataByIdentifierPayload', () {
    test('builds the 22-prefixed command for the given DID', () {
      final payload = readDataByIdentifierPayload(
        'F40C',
        '7E8 04 62 F4 0C 2A',
        responder: '7E8',
      );

      expect(payload, [0x2A]);
    });
  });
}
