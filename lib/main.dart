import 'package:flutter/material.dart';

import 'power/power_monitor.dart';
import 'ui/recording_page.dart';
import 'ui/theme.dart';

void main() {
  runApp(const DidscoutApp());
}

class DidscoutApp extends StatelessWidget {
  const DidscoutApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'didscout',
      theme: didscoutLightTheme(),
      darkTheme: didscoutDarkTheme(),
      themeMode: ThemeMode.system,
      home: RecordingPage(powerMonitor: PowerMonitor()),
    );
  }
}
