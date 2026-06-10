import 'package:flutter/material.dart';

class AppTheme {
  static const Color primaryColor = Color(0xFF00D4AA);
  static const Color surfaceColor = Color(0xFF1A1D2E);
  static const Color backgroundDark = Color(0xFF0F1121);
  static const Color cardDark = Color(0xFF242740);
  static const Color errorColor = Color(0xFFFF4D6D);
  static const Color warningColor = Color(0xFFFFC300);
  static const Color successColor = Color(0xFF00D4AA);

  static ThemeData get darkTheme => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: primaryColor,
          surface: surfaceColor,
          error: errorColor,
        ),
        scaffoldBackgroundColor: backgroundDark,
        appBarTheme: const AppBarTheme(
          backgroundColor: surfaceColor,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        cardTheme: const CardThemeData(
          color: cardDark,
          elevation: 0,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: primaryColor,
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      );

  static ThemeData get lightTheme => ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: const ColorScheme.light(
          primary: primaryColor,
          error: errorColor,
        ),
      );
}
