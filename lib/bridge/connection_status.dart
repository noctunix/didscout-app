/// Which case of a recording's connection [ConnectionStatus] currently
/// describes. Named distinctly from Flutter's own `ConnectionState`
/// (`async.dart`), which this has nothing to do with.
enum RecordingConnectionState { connected, reconnecting, stopped }

/// A recording's connection status, derived from the bridge's own recording
/// and link state — displayed on the recording page while a recording is
/// running.
class ConnectionStatus {
  const ConnectionStatus.connected()
    : state = RecordingConnectionState.connected,
      reconnectingSince = null,
      reconnectAttempt = null,
      stoppedReason = null;

  const ConnectionStatus.reconnecting({
    required DateTime since,
    required int attempt,
  }) : state = RecordingConnectionState.reconnecting,
       reconnectingSince = since,
       reconnectAttempt = attempt,
       stoppedReason = null;

  const ConnectionStatus.stopped(String reason)
    : state = RecordingConnectionState.stopped,
      reconnectingSince = null,
      reconnectAttempt = null,
      stoppedReason = reason;

  final RecordingConnectionState state;

  /// Set only for [RecordingConnectionState.reconnecting]: when the current gap
  /// started.
  final DateTime? reconnectingSince;

  /// Set only for [RecordingConnectionState.reconnecting]: how many consecutive
  /// polls (not the plugin's own internal backoff attempts, which this
  /// package has no way to read) have found the link still down since
  /// [reconnectingSince].
  final int? reconnectAttempt;

  /// Set only for [RecordingConnectionState.stopped]: why native ended the recording
  /// on its own.
  final String? stoppedReason;
}

/// Renders [status] for display: `Connected`, `Reconnecting since HH:mm
/// (attempt n)`, or `Stopped: ` followed by the reason.
String describeConnectionStatus(ConnectionStatus status) {
  switch (status.state) {
    case RecordingConnectionState.connected:
      return 'Connected';
    case RecordingConnectionState.reconnecting:
      final local = status.reconnectingSince!.toLocal();
      String two(int value) => value.toString().padLeft(2, '0');
      return 'Reconnecting since ${two(local.hour)}:${two(local.minute)} '
          '(attempt ${status.reconnectAttempt})';
    case RecordingConnectionState.stopped:
      return 'Stopped: ${status.stoppedReason}';
  }
}
