import 'package:didscout_app/capture/capture_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('readCaptureJsonl', () {
    test('parses well-formed entries and ignores unknown keys', () {
      final jsonl = [
        '{"stage":"sweep","state":"idle","mtu":185,"command":"22F40C",'
            '"response":"7E8 03 62 F4 0C 2A","status":"OK",'
            '"started_utc":"2026-01-01T10:00:00.000Z","module":"bms","extra":"ignored"}',
        '{"stage":"notes","command":"NOTE","response":"plugged in",'
            '"status":"NOTE","started_utc":"2026-01-01T10:00:05.000Z"}',
      ].join('\n');

      final result = readCaptureJsonl(jsonl);

      expect(result.malformedLines, isEmpty);
      expect(result.entries, hasLength(2));
      final first = result.entries[0];
      expect(first.stage, 'sweep');
      expect(first.command, '22F40C');
      expect(first.module, 'bms');
      expect(first.isNote, isFalse);
      expect(first.startedUtc, DateTime.utc(2026, 1, 1, 10, 0, 0));
      expect(result.entries[1].isNote, isTrue);
      expect(result.entries[1].response, 'plugged in');
    });

    test('reports malformed lines without throwing', () {
      final jsonl = [
        'not json at all',
        '["an", "array", "not", "an", "object"]',
        '{"stage":"sweep","command":"22F40C"}', // missing required fields
        '{"stage":"sweep","command":"22F40C","response":"","status":"OK",'
            '"started_utc":"not-a-date"}',
        '',
        '   ',
        '{"stage":"sweep","command":"22F40C","response":"","status":"OK",'
            '"started_utc":"2026-01-01T10:00:00.000Z"}',
      ].join('\n');

      final result = readCaptureJsonl(jsonl);

      expect(result.entries, hasLength(1));
      expect(result.malformedLines, hasLength(4));
      expect(result.malformedLines[0].lineNumber, 1);
      expect(result.malformedLines[1].lineNumber, 2);
      expect(result.malformedLines[2].lineNumber, 3);
      expect(result.malformedLines[3].lineNumber, 4);
    });
  });
}
