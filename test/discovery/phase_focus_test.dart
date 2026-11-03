import 'package:flutter_test/flutter_test.dart';

import 'package:didscout_app/discovery/discovery_state.dart';
import 'package:didscout_app/discovery/phase_focus.dart';

void main() {
  final now = DateTime.utc(2026, 10, 28, 12, 0);

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
    DiscoveryState state,
    Set<String> headers, {
    bool stationary = false,
  }) => [
    for (final read in phaseFocusReads(
      state,
      headers,
      stationary: stationary,
      now: now,
    ))
      '${read.ecuId}/${read.did}',
  ];

  test('leaves out ECUs outside the focus, identification DIDs assumed '
      'stable, and VIN and serial DIDs', () {
    final state = DiscoveryState(
      ecus: {
        'a': ecu('74A', {'2A01', '2A00', 'F187', 'F18C', 'F190', 'F802'}),
        'b': ecu('742', {'2600'}),
      },
    );
    // Changed values keep the identification-range DIDs from counting as
    // stable, so only the VIN/serial filter can keep them out.
    for (final did in ['F18C', 'F190']) {
      state.ecus['a']!.sampleStats[did] = DidSampleStats(everChanged: true);
    }

    expect(readsOf(state, {'74A'}), ['a/2A00', 'a/2A01']);
  });

  test('leaves out an ECU paused asleep, and one the moving blocklist keeps '
      'out unless stationary', () {
    const pause = Duration(minutes: 1);
    final state = DiscoveryState(
      ecus: {
        'asleep': ecu('74A', {'2A00'}, asleepUntil: now.add(pause)),
        'awake': ecu('74B', {'2A00'}, asleepUntil: now.subtract(pause)),
        'unnamed': ecu('73E', {'2A00'}, name: null),
      },
    );
    const headers = {'74A', '74B', '73E'};

    expect(readsOf(state, headers), ['awake/2A00']);
    expect(readsOf(state, headers, stationary: true), [
      'awake/2A00',
      'unnamed/2A00',
    ]);
  });

  group('nextFocusSample', () {
    List<EcuDidRead> readsFor(int count) => [
      for (var i = 0; i < count; i++)
        (
          ecuId: 'a',
          requestHeader: '74A',
          responseHeader: '7B4',
          protocol: 6,
          did: (0x2A00 + i).toRadixString(16).toUpperCase(),
        ),
    ];

    test('movers take at most maxMoverFocusReads, rotating, and the others '
        'fill the rest of the sample', () {
      final reads = readsFor(maxPhaseFocusReads * 2);
      // Every even read moves: maxPhaseFocusReads movers in all.
      bool isMover(EcuDidRead read) => reads.indexOf(read).isEven;

      final first = nextFocusSample(
        reads,
        isMover: isMover,
        moverCursor: 0,
        restCursor: 0,
      );
      final second = nextFocusSample(
        reads,
        isMover: isMover,
        moverCursor: first.moverCursor,
        restCursor: first.restCursor,
      );

      expect(first.sample, hasLength(maxPhaseFocusReads));
      expect(first.sample.take(maxMoverFocusReads).map(reads.indexOf), [
        for (var i = 0; i < maxMoverFocusReads; i++) 2 * i,
      ]);
      expect(first.sample.skip(maxMoverFocusReads).map(reads.indexOf), [
        for (var i = 0; i < maxPhaseFocusReads - maxMoverFocusReads; i++)
          2 * i + 1,
      ]);
      expect(
        second.sample.first,
        reads[2 * maxMoverFocusReads],
        reason: 'the movers left out last time come first',
      );
    });

    test('without movers, rotates through all reads', () {
      final reads = readsFor(maxPhaseFocusReads + 10);

      final first = nextFocusSample(
        reads,
        isMover: (_) => false,
        moverCursor: 0,
        restCursor: 0,
      );
      final second = nextFocusSample(
        reads,
        isMover: (_) => false,
        moverCursor: first.moverCursor,
        restCursor: first.restCursor,
      );

      expect(first.sample, reads.take(maxPhaseFocusReads));
      expect(second.sample, [
        ...reads.skip(maxPhaseFocusReads),
        ...reads.take(maxPhaseFocusReads - 10),
      ]);
    });

    test('no reads, no sample', () {
      final next = nextFocusSample(
        const [],
        isMover: (_) => true,
        moverCursor: 3,
        restCursor: 5,
      );

      expect(next.sample, isEmpty);
      expect((next.moverCursor, next.restCursor), (0, 0));
    });
  });
}
