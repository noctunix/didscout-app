import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/capture/readings.dart';
import 'package:didscout_app/discovery/discovery_state.dart';
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
        'preconditioning',
        'seat-heating',
        'steering-wheel-heating',
        'rear-window-heating',
        'lights',
        'hazard-lights',
        'lock',
        'tailgate',
        'phone-charger',
        'drive-select',
        'recuperation-level',
        'charge-limit',
      ]);
      expect(_ids(experimentCatalog).toSet(), hasLength(22));
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
      '70C',
      '70E',
      '742',
      '17FC008B',
      '17FC00A5',
      '17FC007B',
      '18DA0FF1',
      '18DA07F1',
      '18DA06F1',
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
        'preconditioning',
        'seat-heating',
        'steering-wheel-heating',
        'rear-window-heating',
        'lights',
        'hazard-lights',
        'lock',
        'tailgate',
        'phone-charger',
        'drive-select',
        'recuperation-level',
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
        'preconditioning',
        'seat-heating',
        'steering-wheel-heating',
        'rear-window-heating',
        'lights',
        'hazard-lights',
        'charge-limit',
      ]);
    });

    test('needs at least one answering target ECU', () {
      List<String> idsFor(MarkerPhase phase, Set<String> headers) => _ids(
        suggestedExperiments(
          phase: phase,
          stationary: true,
          answeringRequestHeaders: headers,
          completedCounts: const {},
        ),
      );

      expect(idsFor(MarkerPhase.park, const {'70E'}), [
        'rear-window-heating',
        'lights',
        'hazard-lights',
        'lock',
        'tailgate',
      ]);
      expect(idsFor(MarkerPhase.stand, const {'70C'}), [
        'steering-wheel-heating',
      ]);
      expect(idsFor(MarkerPhase.charge, const {'742'}), ['preconditioning']);
      expect(idsFor(MarkerPhase.park, const {'18DA06F1'}), [
        'recuperation-level',
      ]);
      expect(idsFor(MarkerPhase.stand, const {'18DA0FF1'}), [
        'drive-select',
        'recuperation-level',
      ]);
      expect(idsFor(MarkerPhase.charge, const {'18DA07F1'}), isEmpty);
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
        [
          'climate-fan',
          'preconditioning',
          'steering-wheel-heating',
          'rear-window-heating',
          'climate-ac',
          'seat-heating',
          'climate-setpoint',
        ],
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

    test('a payload that grew or shrank counts as changed', () {
      final changes = experimentChanges(
        before: {
          '74A': {
            '2A10': _bytes([0x00, 0x11]),
            '2A11': _bytes([0x01, 0x02, 0x03]),
          },
        },
        after: {
          '74A': {
            '2A10': _bytes([0x00, 0x11, 0x22]),
            '2A11': _bytes([0x09, 0x02]),
          },
        },
      );

      final diffs = changes['74A']!;
      expect([for (final diff in diffs) diff.did], ['2A10', '2A11']);
      expect(diffs[0].changes, isEmpty);
      expect((diffs[0].before.length, diffs[0].after.length), (2, 3));
      expect(
        [
          for (final change in diffs[1].changes)
            (change.position, change.before, change.after),
        ],
        [(0, 0x01, 0x09)],
      );
      expect((diffs[1].before.length, diffs[1].after.length), (3, 2));
    });
  });

  group('unreturnedChanges', () {
    test('names the changes whose undone payload is not the before one, '
        'or missing', () {
      final changes = experimentChanges(
        before: {
          '74A': {
            '2A00': _bytes([0x00]),
            '2A01': _bytes([0x10, 0x20]),
            '2A02': _bytes([0x05]),
            '2A03': _bytes([0x07]),
          },
          '767': {
            '1234': _bytes([0x01]),
          },
        },
        after: {
          '74A': {
            '2A00': _bytes([0x01]),
            '2A01': _bytes([0x10, 0x21]),
            '2A02': _bytes([0x06]),
            '2A03': _bytes([0x08]),
          },
          '767': {
            '1234': _bytes([0x02]),
          },
        },
      );

      expect(
        unreturnedChanges(
          changes: changes,
          undone: {
            '74A': {
              '2A00': _bytes([0x00]),
              '2A01': _bytes([0x10, 0x21]),
              '2A02': _bytes([0x09]),
            },
          },
        ),
        {
          (header: '74A', did: '2A01'),
          (header: '74A', did: '2A02'),
          (header: '74A', did: '2A03'),
          (header: '767', did: '1234'),
        },
      );
    });

    test('a payload back at its before length and bytes has returned', () {
      final changes = experimentChanges(
        before: {
          '74A': {
            '2A00': _bytes([0x00, 0x11]),
          },
        },
        after: {
          '74A': {
            '2A00': _bytes([0x00, 0x11, 0x22]),
          },
        },
      );

      expect(
        unreturnedChanges(
          changes: changes,
          undone: {
            '74A': {
              '2A00': _bytes([0x00, 0x11]),
            },
          },
        ),
        isEmpty,
      );
      expect(
        unreturnedChanges(
          changes: changes,
          undone: {
            '74A': {
              '2A00': _bytes([0x00]),
            },
          },
        ),
        {(header: '74A', did: '2A00')},
      );
    });
  });

  group('experimentReads', () {
    final now = DateTime.utc(2026, 11, 2, 12);
    final doorDriver = experimentCatalog.firstWhere(
      (experiment) => experiment.id == 'door-driver',
    );

    EcuInfo ecu(
      String request,
      Set<String> discovered, {
      String? name = 'Door FL',
      DateTime? asleepUntil,
    }) => EcuInfo(
      requestHeader: request,
      responseHeader: '7B4',
      protocol: 6,
      identification: {'F197': ?name},
      discovered: discovered,
      asleepUntil: asleepUntil,
    );

    List<String> readsOf(
      DiscoveryState state, {
      bool includeProfileDids = false,
      bool stationary = true,
    }) => [
      for (final read in experimentReads(
        state,
        doorDriver,
        includeProfileDids: includeProfileDids,
        stationary: stationary,
        now: now,
      ))
        '${read.ecuId}/${read.did}',
    ];

    test('reads every found DID of the target ECUs, never VIN or serial '
        'DIDs', () {
      final state = DiscoveryState(
        ecus: {
          'b': ecu('74A', {'2A01', 'f187', 'F18C', 'F190', 'F802'}),
          'a': ecu('74A', {'2A00'}),
          'other': ecu('74B', {'2A00'}),
        },
      );
      state.ecus['b']!.sampleStats['2A01'] = DidSampleStats(
        lastPayloadHash: 1,
        stableSamples: 1000,
        stableRecordings: 100,
      );

      expect(readsOf(state), ['a/2A00', 'b/2A01', 'b/F187']);
    });

    test('adds the profile DIDs of a seeded ECU only when asked to', () {
      final state = DiscoveryState(
        ecus: {
          'door-front-left': ecu('74A', {'2A00'}),
        },
      );

      expect(readsOf(state), ['door-front-left/2A00']);
      expect(readsOf(state, includeProfileDids: true), [
        'door-front-left/2A00',
        'door-front-left/F197',
      ]);
    });

    test('leaves out an ECU asleep, one without a responder, and one the '
        'moving blocklist keeps out unless stationary', () {
      final state = DiscoveryState(
        ecus: {
          'asleep': ecu('74A', {
            '2A00',
          }, asleepUntil: now.add(const Duration(minutes: 1))),
          'mute': EcuInfo(
            requestHeader: '74A',
            protocol: 6,
            identification: {'F197': 'Door FL'},
            discovered: {'2A00'},
          ),
          'unnamed': ecu('74A', {'2A00'}, name: null),
        },
      );

      expect(readsOf(state), ['unnamed/2A00']);
      expect(readsOf(state, stationary: false), isEmpty);
    });

    test('stops after maxExperimentReads reads', () {
      final dids = [
        for (var i = 0; i < maxExperimentReads + 5; i++)
          (0x2A00 + i).toRadixString(16).toUpperCase(),
      ];
      final state = DiscoveryState(
        ecus: {
          'a': ecu('74A', dids.toSet()),
          'b': ecu('74A', {'2A00'}),
        },
      );

      expect(readsOf(state), [
        for (final did in dids.take(maxExperimentReads)) 'a/$did',
      ]);
    });
  });
}
