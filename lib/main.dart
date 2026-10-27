import 'package:flutter/material.dart';

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
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('didscout')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Recording is not implemented yet.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
