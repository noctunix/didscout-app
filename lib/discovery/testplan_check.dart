/// A fixed, one-shot probe catalogue testing standing hypotheses about
/// what this vehicle platform answers beyond its own discovered DIDs:
/// the classic mode 01 PIDs, their OBDonUDS equivalents, and a handful of
/// manufacturer-specific hypotheses (gateway, tyre pressure). Runs once
/// shortly after a recording connects and once more per vehicle phase
/// change, never resending a probe the vehicle already answered.
library;

import 'dart:async';

import '../session/session_markers.dart' show MarkerPhase;
import 'inventory.dart' show ecu11ReceiveFilter, ecu11ReceiveMask;
import 'probe.dart';

/// Fixed floor of one probe group's result-wait deadline, plus
/// [testplanDeadlinePerStep] per probe in the group and per read queued
/// ahead of it -- the same base/
/// per-step idiom `DiscoveryEngine` uses for its own batches, sized for a
/// one-shot group of at most a few dozen probes.
const Duration testplanDeadlineBase = Duration(seconds: 15);

/// Added to [testplanDeadlineBase] once per probe in a group and once per
/// read queued ahead of it.
const Duration testplanDeadlinePerStep = Duration(seconds: 2);

/// The three probe groups the catalogue runs in order.
enum TestplanGroup {
  mode01('Mode 01'),
  obdOnUds('OBDonUDS'),
  hypotheses('Hypotheses');

  const TestplanGroup(this.label);

  /// Short English label for the card.
  final String label;
}

/// One fixed probe in the catalogue: where to send it and what a
/// positive reply means for the recurring survey.
class TestplanProbe {
  const TestplanProbe({
    required this.group,
    required this.moduleId,
    required this.requestHeader,
    this.responseHeader,
    required this.protocol,
    required this.command,
    required this.description,
    this.receiveFilter,
    this.receiveMask,
    this.countsTowardSurvey = false,
  });

  final TestplanGroup group;

  /// Never contains an underscore -- see [signalId].
  final String moduleId;

  final String requestHeader;

  /// Null for a module whose responder isn't addressed back (the
  /// functional mode 01 sweep); see [ProbeModule.responseHeader].
  final String? responseHeader;

  /// Wire protocol: 6 (11-bit CAN) or 7 (29-bit CAN).
  final int protocol;

  /// The mode 01/UDS command, e.g. `0100` or `22F45B`.
  final String command;

  /// Short English description for the card.
  final String description;

  final String? receiveFilter;
  final String? receiveMask;

  /// Whether a positive reply should be folded into the recurring survey
  /// once its request header matches a known ECU -- never for a mode 01
  /// PID (never matches a known physical header) or an OBDonUDS
  /// supported-PIDs bitmap (`22F4x0`), which answer "is this readable"
  /// rather than carry a signal of their own.
  final bool countsTowardSurvey;

  /// `<moduleId>_<commandlowercase>`, prefixed `testplan` through every
  /// [moduleId] in the catalogue -- stable across runs, so log analysis
  /// can find a probe's exchanges in the recording buffer.
  String get signalId => signalIdFor(moduleId, command);

  /// The UDS DID [command] reads (4 hex digits), for a `22` command;
  /// null for a mode 01 PID.
  String? get did => command.startsWith('22') ? command.substring(2) : null;

  ProbeModule toModule() => ProbeModule(
    id: moduleId,
    requestHeader: requestHeader,
    responseHeader: responseHeader,
    protocol: protocol,
    receiveFilter: receiveFilter,
    receiveMask: receiveMask,
  );

  ProbeStep toStep() => ProbeStep(signalId: signalId, command: command);
}

const String _mode1ModuleId = 'testplanMode1';
const String _mode1RequestHeader = '7DF';

const List<(String, String)> _mode01Commands = [
  ('0100', 'Supported PIDs 01-20'),
  ('0120', 'Supported PIDs 21-40'),
  ('0140', 'Supported PIDs 41-60'),
  ('0160', 'Supported PIDs 61-80'),
  ('0180', 'Supported PIDs 81-A0'),
  ('01A0', 'Supported PIDs A1-C0'),
  ('01C0', 'Supported PIDs C1-E0'),
  ('015B', 'Hybrid battery pack remaining life'),
  ('019A', 'Hybrid/EV vehicle system data'),
  ('010D', 'Vehicle speed'),
  ('0146', 'Ambient air temperature'),
  ('0142', 'Control module voltage'),
  ('01A6', 'Odometer'),
  ('01D0', 'Candidate PID, undocumented in public tables'),
  ('01D2', 'Candidate PID, undocumented in public tables'),
  ('01D8', 'Candidate PID, undocumented in public tables'),
];

/// The classic PIDs, sent functionally (`7DF`) with the same any-header
/// receive filter the 11-bit ECU inventory sweep uses: a mode 01 reply is
/// always single-frame, so no flow control is needed, and which engine/
/// transmission/etc. ECU actually answers is left for [ProbeResult.
/// responderHeader] to report.
List<TestplanProbe> _mode01Probes() => [
  for (final (command, description) in _mode01Commands)
    TestplanProbe(
      group: TestplanGroup.mode01,
      moduleId: _mode1ModuleId,
      requestHeader: _mode1RequestHeader,
      protocol: 6,
      receiveFilter: ecu11ReceiveFilter,
      receiveMask: ecu11ReceiveMask,
      command: command,
      description: description,
    ),
];

const List<(String, String, bool)> _obdOnUdsCommands = [
  ('22F400', 'Supported PIDs 01-20 (bitmap)', false),
  ('22F420', 'Supported PIDs 21-40 (bitmap)', false),
  ('22F440', 'Supported PIDs 41-60 (bitmap)', false),
  ('22F460', 'Supported PIDs 61-80 (bitmap)', false),
  ('22F480', 'Supported PIDs 81-A0 (bitmap)', false),
  ('22F4A0', 'Supported PIDs A1-C0 (bitmap)', false),
  ('22F4C0', 'Supported PIDs C1-E0 (bitmap)', false),
  ('22F45B', 'Hybrid battery pack remaining life', true),
  ('22F49A', 'Hybrid/EV vehicle system data', true),
  ('22F4D0', 'Candidate PID, undocumented in public tables', true),
  ('22F4D2', 'Candidate PID, undocumented in public tables', true),
  ('22F4D8', 'Candidate PID, undocumented in public tables', true),
];

/// The same PIDs as [_mode01Probes], addressed as UDS DIDs (`F4` plus the
/// PID byte) on one normal-fixed-addressing module.
List<TestplanProbe> _obdOnUdsProbes(
  String moduleId,
  String requestHeader,
  String responseHeader,
) => [
  for (final (command, description, countsTowardSurvey) in _obdOnUdsCommands)
    TestplanProbe(
      group: TestplanGroup.obdOnUds,
      moduleId: moduleId,
      requestHeader: requestHeader,
      responseHeader: responseHeader,
      protocol: 7,
      command: command,
      description: description,
      countsTowardSurvey: countsTowardSurvey,
    ),
];

List<TestplanProbe> _obdOnUdsAllProbes() => [
  ..._obdOnUdsProbes('testplanUds04', '18DA04F1', '18DAF104'),
  ..._obdOnUdsProbes('testplanUds06', '18DA06F1', '18DAF106'),
  ..._obdOnUdsProbes('testplanUds07', '18DA07F1', '18DAF107'),
];

const List<(String, String)> _gatewayCommands = [
  ('222AF7', 'Candidate gateway DID (hypothesis)'),
  ('222AB2', 'Candidate gateway DID (hypothesis)'),
  ('222AB6', 'Range estimate (cross-check against the known read)'),
  ('222AB7', 'Candidate gateway DID (hypothesis)'),
  ('222AB8', 'Stored energy (cross-check against the known read)'),
];

const List<(String, String)> _tyreCommands = [
  ('2218A0', 'Candidate tyre pressure DID, front left (hypothesis)'),
  ('2218A1', 'Candidate tyre pressure DID, front right (hypothesis)'),
  ('2218A2', 'Candidate tyre pressure DID, rear left (hypothesis)'),
  ('2218A3', 'Candidate tyre pressure DID, rear right (hypothesis)'),
];

List<TestplanProbe> _hypothesesProbes() => [
  for (final (command, description) in _gatewayCommands)
    TestplanProbe(
      group: TestplanGroup.hypotheses,
      moduleId: 'testplanGateway',
      requestHeader: '710',
      responseHeader: '77A',
      protocol: 6,
      command: command,
      description: description,
      countsTowardSurvey: true,
    ),
  for (final (command, description) in _tyreCommands)
    TestplanProbe(
      group: TestplanGroup.hypotheses,
      moduleId: 'testplanTyres',
      requestHeader: '70B',
      responseHeader: '775',
      protocol: 6,
      command: command,
      description: description,
      countsTowardSurvey: true,
    ),
];

/// The fixed testplan probe catalogue, in run order: mode 01 first, then
/// OBDonUDS, then the manufacturer hypotheses.
List<TestplanProbe> testplanProbes() => [
  ..._mode01Probes(),
  ..._obdOnUdsAllProbes(),
  ..._hypothesesProbes(),
];

/// How a [TestplanProbe]'s most recent run ended up, for the card.
enum TestplanOutcome {
  /// Never submitted yet this recording.
  notRun,

  /// Submitted; no result yet.
  running,

  /// A positive response was received.
  ok,

  /// A negative response code was received.
  nrc,

  /// The responder answered "NO DATA".
  noData,

  /// The adapter timed out waiting for a reply.
  timeout,

  /// Cancelled, or left without any result by its own deadline -- may be
  /// retried on the next run.
  cancelledOrMissing,
}

/// Mutable run state for one [TestplanProbe], owned by [TestplanCheck].
class TestplanProbeState {
  TestplanProbeState(this.probe);

  final TestplanProbe probe;
  bool pending = false;
  bool everSubmitted = false;
  ProbeStatus? lastStatus;
  int? payloadLength;

  /// Whether the vehicle (or the adapter, for a timeout) gave a
  /// conclusive answer -- cancelled/missing never counts, so it stays
  /// eligible for a retry on the next run.
  bool get answered => switch (lastStatus) {
    ProbeOk() || ProbeNoData() || ProbeNrc() || ProbeTimeout() => true,
    ProbeCancelled() || ProbeTransportError() || null => false,
  };

  TestplanOutcome get outcome {
    if (pending) return TestplanOutcome.running;
    if (!everSubmitted) return TestplanOutcome.notRun;
    return switch (lastStatus) {
      null => TestplanOutcome.cancelledOrMissing,
      ProbeOk() => TestplanOutcome.ok,
      ProbeNrc() => TestplanOutcome.nrc,
      ProbeNoData() => TestplanOutcome.noData,
      ProbeTimeout() => TestplanOutcome.timeout,
      ProbeCancelled() ||
      ProbeTransportError() => TestplanOutcome.cancelledOrMissing,
    };
  }

  /// Short status text for the card, e.g. `OK (+4B)` or `NRC 11`.
  String get statusLabel => switch (outcome) {
    TestplanOutcome.notRun => 'not run yet',
    TestplanOutcome.running => 'running',
    TestplanOutcome.ok => 'OK (+${payloadLength ?? 0}B)',
    TestplanOutcome.nrc =>
      'NRC ${(lastStatus as ProbeNrc).code.toRadixString(16).toUpperCase().padLeft(2, '0')}',
    TestplanOutcome.noData => 'NO DATA',
    TestplanOutcome.timeout => 'timeout',
    TestplanOutcome.cancelledOrMissing => 'cancelled/missing',
  };
}

/// Drives [testplanProbes] against [executor]: [runForPhase] submits
/// every not-yet-answered probe, once per distinct phase value for the
/// life of this instance (one recording) -- the caller is expected to
/// call it once shortly after connecting, with whatever phase is current
/// then, and again on every later phase change. Every [TestplanProbe.
/// signalId] in the catalogue is unique to this check, so its results
/// need no claiming against discovery's own: this subscribes to
/// [executor]'s result stream directly, exactly like [DiscoveryEngine]
/// does for its own batches.
class TestplanCheck {
  TestplanCheck({
    required this.executor,
    this.onResult,
    List<TestplanProbe>? probes,
    Future<void> Function(Duration)? delay,
  }) : probes = probes ?? testplanProbes(),
       _delay = delay ?? Future<void>.delayed {
    states = {
      for (final probe in this.probes)
        probe.signalId: TestplanProbeState(probe),
    };
    _subscription = executor.results.listen(_handleResult);
  }

  final ReadExecutor executor;
  final List<TestplanProbe> probes;

  /// Called once per probe result, after this check's own bookkeeping --
  /// lets the caller fold a survey-eligible positive reply into
  /// discovery state, or quarantine a timed-out DID, without this class
  /// needing to know about `DiscoveryState`.
  final void Function(TestplanProbe probe, ProbeResult result)? onResult;

  final Future<void> Function(Duration) _delay;
  late final StreamSubscription<ProbeResult> _subscription;

  /// Current status per probe, keyed by [TestplanProbe.signalId].
  late final Map<String, TestplanProbeState> states;

  final Set<MarkerPhase?> _ranForPhase = {};
  final Map<String, Completer<ProbeResult>> _awaiting = {};

  /// The phase the most recently completed run served, for the card's
  /// "last run" line -- null before the first run.
  MarkerPhase? lastRunPhase;

  int get totalCount => states.length;

  int get answeredCount =>
      states.values.where((state) => state.answered).length;

  int get okCount => states.values
      .where((state) => state.outcome == TestplanOutcome.ok)
      .length;

  /// [states], grouped by [TestplanProbe.group] in catalogue order.
  Map<TestplanGroup, List<TestplanProbeState>> get statesByGroup => {
    for (final group in TestplanGroup.values)
      group: [
        for (final state in states.values)
          if (state.probe.group == group) state,
      ],
  };

  void _handleResult(ProbeResult result) {
    _awaiting.remove(result.signalId)?.complete(result);
  }

  /// Cancels the subscription to [executor]'s result stream; call once
  /// the recording this check serves has ended.
  void dispose() => _subscription.cancel();

  /// Runs every not-yet-answered probe against [phase]; a no-op once
  /// [phase] already had a run this recording.
  Future<void> runForPhase(MarkerPhase? phase) async {
    if (!_ranForPhase.add(phase)) return;
    for (final group in TestplanGroup.values) {
      await _runGroup(group);
    }
    lastRunPhase = phase;
  }

  Future<void> _runGroup(TestplanGroup group) async {
    final due = [
      for (final state in states.values)
        if (state.probe.group == group && !state.answered) state,
    ];
    if (due.isEmpty) return;
    final modules = <String, ProbeModule>{};
    final steps = <ProbeStep>[];
    final completers = <String, Completer<ProbeResult>>{};
    for (final state in due) {
      final probe = state.probe;
      modules.putIfAbsent(probe.moduleId, probe.toModule);
      steps.add(probe.toStep());
      completers[probe.signalId] = Completer<ProbeResult>();
      state.pending = true;
      state.everSubmitted = true;
    }
    _awaiting.addAll(completers);
    final queuedAhead = executor.queueDepth;
    try {
      await executor.submit(modules.values.toList(), steps);
    } on ReadExecutorRejection {
      for (final state in due) {
        state.pending = false;
        _awaiting.remove(state.probe.signalId);
      }
      return;
    }
    final deadline =
        testplanDeadlineBase +
        testplanDeadlinePerStep * (queuedAhead + steps.length);
    await Future.wait([
      for (final state in due)
        _awaitProbeOrDeadline(
          state,
          completers[state.probe.signalId]!,
          deadline,
        ),
    ]);
  }

  Future<void> _awaitProbeOrDeadline(
    TestplanProbeState state,
    Completer<ProbeResult> completer,
    Duration deadline,
  ) async {
    final result = await Future.any<ProbeResult?>([
      completer.future.then<ProbeResult?>((r) => r),
      _delay(deadline).then((_) => null),
    ]);
    state.pending = false;
    if (result == null) {
      // Expired -- drop it from `_awaiting` so a result that does arrive
      // later for this signal id is ignored rather than mis-delivered to
      // whatever run happens to reuse it next.
      _awaiting.remove(state.probe.signalId);
      return;
    }
    state.lastStatus = result.status;
    state.payloadLength = result.payload?.length;
    onResult?.call(state.probe, result);
  }
}
