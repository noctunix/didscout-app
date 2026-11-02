import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/capture/readings.dart';
import 'package:didscout_app/session/experiments.dart';
import 'package:didscout_app/session/session_markers.dart';

List<String> _ids(List<Experiment> experiments) => [
  for (final experiment in experiments) experiment.id,
];

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

void main() {
  group('experimentCatalog', () {
    test('ids are the fixed marker spellings, unique and in order', () {
      expect(_ids(experimentCatalog), [
        'charge-flap-left',
        'charge-flap-right',
        'door-driver',
        'door-passenger',
        'door-rear-left',
        'door-rear-right',
        'window-driver',
        'climate-setpoint',
        'climate-ac',
        'climate-fan',
        'seat-heating',
        'lights',
        'lock',
        'tailgate',
        'phone-charger',
        'charge-limit',
      ]);
      expect(_ids(experimentCatalog).toSet(), hasLength(16));
    });

    test('follow-up readings are asked only where the action moves one', () {
      expect(
        {
          for (final experiment in experimentCatalog)
            experiment.id: ?experiment.followUp,
        },
        {
          'climate-setpoint': ReadingQuantity.insideTemp,
          'charge-limit': ReadingQuantity.soc,
        },
      );
    });
  });

  group('suggestedExperiments', () {
    const allHeaders = {
      '17FC0082',
      '17FC0083',
      '74A',
      '74B',
      '73E',
      '73F',
      '767',
      '74C',
      '70E',
      '17FC008B',
      '17FC00A5',
      '17FC007B',
      '18DA0FF1',
      '710',
    };

    test('suggests nothing while the vehicle moves', () {
      for (final phase in MarkerPhase.values) {
        expect(
          suggestedExperiments(
            phase: phase,
            stationary: false,
            answeringRequestHeaders: allHeaders,
            completedCounts: const {},
          ),
          isEmpty,
        );
      }
    });

    test('suggests nothing before a phase is chosen', () {
      expect(
        suggestedExperiments(
          phase: null,
          stationary: true,
          answeringRequestHeaders: allHeaders,
          completedCounts: const {},
        ),
        isEmpty,
      );
    });

    test('suggests nothing in the drive phase, even when stationary', () {
      expect(
        suggestedExperiments(
          phase: MarkerPhase.drive,
          stationary: true,
          answeringRequestHeaders: allHeaders,
          completedCounts: const {},
        ),
        isEmpty,
      );
    });

    test('filters by phase', () {
      List<String> idsIn(MarkerPhase phase) => _ids(
        suggestedExperiments(
          phase: phase,
          stationary: true,
          answeringRequestHeaders: allHeaders,
          completedCounts: const {},
        ),
      );

      final standOrPark = [
        'charge-flap-left',
        'charge-flap-right',
        'door-driver',
        'door-passenger',
        'door-rear-left',
        'door-rear-right',
        'window-driver',
        'climate-setpoint',
        'climate-ac',
        'climate-fan',
        'seat-heating',
        'lights',
        'lock',
        'tailgate',
        'phone-charger',
      ];
      expect(idsIn(MarkerPhase.stand), standOrPark);
      expect(idsIn(MarkerPhase.park), standOrPark);
      expect(idsIn(MarkerPhase.charge), [
        'charge-flap-left',
        'charge-flap-right',
        'door-driver',
        'door-passenger',
        'door-rear-left',
        'door-rear-right',
        'climate-setpoint',
        'climate-ac',
        'climate-fan',
        'seat-heating',
        'lights',
        'charge-limit',
      ]);
    });

    test('needs at least one answering target ECU', () {
      expect(
        _ids(
          suggestedExperiments(
            phase: MarkerPhase.park,
            stationary: true,
            answeringRequestHeaders: const {'70E'},
            completedCounts: const {},
          ),
        ),
        ['lights', 'lock', 'tailgate'],
      );
      expect(
        suggestedExperiments(
          phase: MarkerPhase.park,
          stationary: true,
          answeringRequestHeaders: const {},
          completedCounts: const {},
        ),
        isEmpty,
      );
    });

    test('orders fewest completions first, then by catalog order', () {
      expect(
        _ids(
          suggestedExperiments(
            phase: MarkerPhase.stand,
            stationary: true,
            answeringRequestHeaders: const {'767', '74C'},
            completedCounts: const {
              'climate-setpoint': 2,
              'climate-ac': 1,
              'seat-heating': 1,
              'door-driver': 5,
            },
          ),
        ),
        ['climate-fan', 'climate-ac', 'seat-heating', 'climate-setpoint'],
      );
    });
  });

  group('experimentChanges', () {
    test('reports the changed bytes of each target ECU', () {
      final changes = experimentChanges(
        before: {
          '74A': {
            '2A10': _bytes([0x00, 0x11, 0x22]),
            '0100': _bytes([0x05, 0x06]),
          },
          '767': {
            '1234': _bytes([0x10]),
          },
        },
        after: {
          '74A': {
            '2A10': _bytes([0x01, 0x11, 0x23]),
            '0100': _bytes([0x05, 0x07]),
          },
          '767': {
            '1234': _bytes([0x10]),
          },
        },
      );

      expect(changes.keys, ['74A']);
      final diffs = changes['74A']!;
      expect([for (final diff in diffs) diff.did], ['0100', '2A10']);
      expect(diffs.every((diff) => diff.module == '74A'), isTrue);
      expect(
        [
          for (final change in diffs[1].changes)
            (change.position, change.before, change.after),
        ],
        [(0, 0x00, 0x01), (2, 0x22, 0x23)],
      );
      expect(diffs[0].before, [0x05, 0x06]);
      expect(diffs[0].after, [0x05, 0x07]);
    });

    test('ignores unchanged DIDs and DIDs read only once', () {
      final changes = experimentChanges(
        before: {
          '74A': {
            '2A10': _bytes([0x00]),
            '2A11': _bytes([0x01]),
          },
          '74B': {
            '2A10': _bytes([0x00]),
          },
        },
        after: {
          '74A': {
            '2A10': _bytes([0x00]),
            '2A12': _bytes([0x02]),
          },
        },
      );

      expect(changes, isEmpty);
    });
  });
}
