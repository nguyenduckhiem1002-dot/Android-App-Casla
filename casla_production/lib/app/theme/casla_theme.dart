// Casla Group Theme — Material 3
// Spec: Section 6

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'casla_colors.dart';

class CaslaTheme {
  CaslaTheme._();

  static ThemeData get light {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: const ColorScheme.light(
        primary: CaslaColors.primaryNavy,
        secondary: CaslaColors.accentGold,
        tertiary: CaslaColors.gold700,
        surface: CaslaColors.surface,
        onPrimary: Colors.white,
        onSecondary: CaslaColors.navy900,
        onSurface: CaslaColors.primaryNavy,
      ),
      scaffoldBackgroundColor: CaslaColors.background,
      appBarTheme: const AppBarTheme(
        backgroundColor: CaslaColors.primaryNavy,
        foregroundColor: Colors.white,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: CaslaColors.primaryNavy,
          statusBarIconBrightness: Brightness.light,
        ),
      ),
      cardTheme: CardThemeData(
        color: CaslaColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: CaslaColors.line),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: CaslaColors.accentGold,
          foregroundColor: CaslaColors.navy900,
          minimumSize: const Size(double.infinity, 54),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14.5,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: CaslaColors.primaryNavy,
          minimumSize: const Size(double.infinity, 48),
          side: const BorderSide(color: CaslaColors.primaryNavy, width: 1.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14.5,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: CaslaColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: CaslaColors.line, width: 1.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: CaslaColors.line, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide:
              const BorderSide(color: CaslaColors.accentGold, width: 2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      ),
      dividerTheme: const DividerThemeData(
        color: CaslaColors.line,
        thickness: 1,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: CaslaColors.surface,
        selectedItemColor: CaslaColors.primaryNavy,
        unselectedItemColor: CaslaColors.muted,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
    );
  }
}
