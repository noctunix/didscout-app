/// Draft didscout-profile TOML from discovered ECUs/DIDs, per the schema
/// in didscout's `CONTRIBUTING.md`. Every DID is written `unverified`
/// with no decoded value -- a human reviews and promotes each one before
/// it becomes a real profile PR.
library;

import 'discovery_state.dart';

/// The `session --survey` default interval (seconds) -- the schema
/// requires an interval on every `survey`-polled DID.
const int profileExportSurveyIntervalSeconds = 60;

/// Builds a profile-draft TOML document from [state]'s known ECUs and
/// discovered DIDs.
String exportProfileDraft(
  DiscoveryState state, {
  required String id,
  required String name,
  required String description,
  List<String> vehicles = const ['vehicle under test'],
}) {
  final buffer = StringBuffer()
    ..writeln('schema = 1')
    ..writeln('id = "$id"')
    ..writeln('name = "$name"')
    ..writeln('description = "$description"')
    ..writeln('protocol = "6"')
    ..writeln('vehicles = [${vehicles.map((v) => '"$v"').join(', ')}]')
    ..writeln()
    ..writeln('[[sources]]')
    ..writeln('title = "Own discovery"')
    ..writeln('url = "https://github.com/noctunix/didscout-app"')
    ..writeln('license = "own discovery"');

  final ecuIds = state.ecus.keys.toList()..sort();
  for (final ecuId in ecuIds) {
    final ecu = state.ecus[ecuId]!;
    buffer
      ..writeln()
      ..writeln('[[modules]]')
      ..writeln('id = "$ecuId"')
      ..writeln('request = "${ecu.requestHeader}"');
    if (ecu.responseHeader != null) {
      buffer.writeln('response = "${ecu.responseHeader}"');
    }
    if (ecu.protocol != 6) {
      buffer.writeln('protocol = "${ecu.protocol}"');
    }

    final dids = ecu.discovered.toList()..sort();
    for (final did in dids) {
      buffer
        ..writeln()
        ..writeln('[[modules.dids]]')
        ..writeln('did = "$did"')
        ..writeln('status = "unverified"')
        ..writeln('poll = "survey"')
        ..writeln('interval = $profileExportSurveyIntervalSeconds');
    }
  }

  return buffer.toString();
}
