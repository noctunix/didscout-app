/// Where a vehicle's [DiscoveryState] lives on disk.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart' as path_provider;

import 'discovery_state.dart';

/// The vehicle label used until the app has a vehicle-selection feature of
/// its own -- every recording today scouts (and reads back) the same one.
const String defaultVehicleLabel = 'vehicle';

/// The file [vehicleLabel]'s [DiscoveryState] is persisted to, under the
/// app's own support directory -- app-internal state, not something a
/// recording ever exports directly (see `profile_export.dart` for that).
Future<File> discoveryStateFile(String vehicleLabel) async {
  final supportDir = await path_provider.getApplicationSupportDirectory();
  return File('${supportDir.path}/discovery/$vehicleLabel.json');
}
