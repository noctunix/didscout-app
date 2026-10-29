import 'package:flutter_test/flutter_test.dart';

/// Waits until [condition] holds (or fails after [timeout]) instead of a fixed
/// sleep, which flakes when the suite runs under load.
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
