import 'package:flutter/material.dart';

/// Brand seed color for didscout's Material 3 color schemes.
const Color didscoutSeedColor = Color(0xFF0099FF);

ThemeData didscoutLightTheme() {
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: didscoutSeedColor),
  );
}

ThemeData didscoutDarkTheme() {
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: didscoutSeedColor,
      brightness: Brightness.dark,
    ),
  );
}
