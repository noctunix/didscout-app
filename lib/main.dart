import 'package:flutter/material.dart';

import 'ui/recording_page.dart';

void main() {
  runApp(const DidscoutApp());
}

class DidscoutApp extends StatelessWidget {
  const DidscoutApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'didscout',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      home: RecordingPage(),
    );
  }
}
