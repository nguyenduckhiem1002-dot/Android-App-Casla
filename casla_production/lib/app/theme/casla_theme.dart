// Casla Group Theme — Material 3
// Spec: Section 6

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'casla_colors.dart';
import 'casla_spacing.dart';

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
      // Typography lives here, once.
      //
      // Screens used to declare `fontFamily: 'Manrope'` (and sometimes
      // 'Inter') inline in about fifty places. Neither font was ever bundled —
      // pubspec has no `fonts:` section and assets/fonts/ does not exist — so
      // every one of those resolved to the platform default anyway. Those
      // declarations are gone; the weights and sizes that actually did the
      // work are expressed here against CaslaType. To adopt a real brand face,
      // add the files under assets/fonts, declare them in pubspec, and set
      // `fontFamily` on this ThemeData — nowhere else.
      textTheme: const TextTheme(
        displaySmall: TextStyle(
          fontSize: CaslaType.display,
          fontWeight: FontWeight.w800,
          height: 1.1,
        ),
        titleLarge: TextStyle(
          fontSize: CaslaType.title,
          fontWeight: FontWeight.w800,
        ),
        titleMedium: TextStyle(
          fontSize: CaslaType.subtitle,
          fontWeight: FontWeight.w700,
        ),
        bodyLarge: TextStyle(fontSize: CaslaType.subtitle),
        bodyMedium: TextStyle(fontSize: CaslaType.body),
        bodySmall: TextStyle(fontSize: CaslaType.caption),
        labelLarge: TextStyle(
          fontSize: CaslaType.body,
          fontWeight: FontWeight.w700,
        ),
        labelMedium: TextStyle(
          fontSize: CaslaType.caption,
          fontWeight: FontWeight.w700,
        ),
      ),
      scaffoldBackgroundColor: CaslaColors.background,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CaslaRadius.md),
        ),
      ),
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
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CaslaRadius.md),
          side: const BorderSide(color: CaslaColors.line, width: 1),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: CaslaColors.accentGold,
          foregroundColor: CaslaColors.navy900,
          elevation: 0,
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CaslaRadius.md),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: CaslaType.body,
            letterSpacing: 0.2,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: CaslaColors.primaryNavy,
          minimumSize: const Size(double.infinity, 50),
          side: const BorderSide(color: CaslaColors.primaryNavy, width: 1.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CaslaRadius.md),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: CaslaType.body,
            letterSpacing: 0.2,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        floatingLabelBehavior: FloatingLabelBehavior.always,
        helperMaxLines: 3,
        errorMaxLines: 3,
        filled: true,
        fillColor: CaslaColors.surface,
        hintStyle: const TextStyle(
          color: CaslaColors.muted,
          fontSize: CaslaType.body,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CaslaRadius.sm),
          borderSide: const BorderSide(color: CaslaColors.line, width: 1.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CaslaRadius.sm),
          borderSide: const BorderSide(color: CaslaColors.line, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CaslaRadius.sm),
          borderSide: const BorderSide(
            color: CaslaColors.primaryNavy,
            width: 1.8,
          ),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CaslaRadius.sm),
          borderSide: const BorderSide(color: CaslaColors.danger, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: CaslaSpacing.md,
          vertical: CaslaSpacing.sm,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: CaslaColors.line,
        thickness: 1,
        space: 1,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        selectedLabelStyle: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: CaslaType.caption,
        ),
        unselectedLabelStyle: TextStyle(
          fontWeight: FontWeight.w500,
          fontSize: CaslaType.caption,
        ),
        backgroundColor: CaslaColors.surface,
        selectedItemColor: CaslaColors.primaryNavy,
        unselectedItemColor: CaslaColors.muted,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
    );
  }
}
