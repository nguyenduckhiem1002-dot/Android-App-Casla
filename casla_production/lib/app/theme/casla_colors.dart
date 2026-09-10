// Casla Group Design System — Color Tokens
// Spec: Section 6.1
// Matching index.html CSS variables exactly

import 'package:flutter/material.dart';

class CaslaColors {
  CaslaColors._();

  // Primary Navy — App bar, heading, navigation, nền đậm
  static const Color primaryNavy = Color(0xFF16234A);
  static const Color navy700 = Color(0xFF1D2E5C);
  static const Color navy900 = Color(0xFF0E1730);

  // Accent Gold — CTA, focus, trạng thái pending
  static const Color accentGold = Color(0xFFC9A24B);
  static const Color gold100 = Color(0xFFF6EAD2);
  // Darkened status text remains legible on white and the light gold surface.
  static const Color gold700 = Color(0xFF765515);

  // Surface & Background
  static const Color surface = Color(0xFFFFFFFF);
  static const Color background = Color(0xFFF5F6F8);
  static const Color line = Color(0xFFE7E9EE);

  // Muted
  // 5.3:1 on white (the former #8A8F9B was below WCAG AA for normal text).
  static const Color muted = Color(0xFF626A78);
  static const Color muted100 = Color(0xFFEEF0F3);

  // Status — Success
  // Darkened from #2E7D32, which measured 4.44:1 on successBg and so missed
  // WCAG AA for the 12sp status-chip label by a hair.
  static const Color success = Color(0xFF236B27);
  static const Color successBg = Color(0xFFE5F2E6);

  /// Success accent for navy surfaces (8.2:1 on navy900).
  static const Color successOnDark = Color(0xFF65C56B);

  // Status — Danger
  static const Color danger = Color(0xFFC62828);
  static const Color dangerBg = Color(0xFFFBEAEA);

  // Status — Pending
  static const Color pending = Color(0xFF85601A);
  static const Color pendingBg = Color(0xFFFBF1DD);

  /// Secondary text on navy surfaces (9.9:1 on navy900).
  ///
  /// Replaces the former #5C6690 device footer, which measured 3.17:1 and was
  /// the only text token in the app failing WCAG AA outright.
  static const Color onDarkSecondary = Color(0xFFB7C1E4);

  /// Lower-emphasis text on navy surfaces. Still passes AA (6.9:1).
  static const Color onDarkMuted = Color(0xFF93A0CC);

  /// Progress-bar fill.
  ///
  /// Brand gold (#C9A24B) measures 2.10:1 against the muted100 track, below
  /// the 3:1 WCAG 1.4.11 floor for graphical objects — and a worker's
  /// completion bar is the main at-a-glance signal on the overview screen.
  /// This deeper gold keeps the brand read at 4.65:1.
  static const Color progressFill = Color(0xFF8A6518);
  static const Color progressTrack = Color(0xFFEEF0F3);

  // Identity bar sub-text
  static const Color identityMeta = Color(0xFFB9C2E4);
  static const Color contextChipText = Color(0xFFDFE4F5);
  static const Color accentLabelDark = Color(0xFFAAB4DD);

  // Banner
  static const Color bannerText = Color(0xFF6B5320);

  static const Color navy100 = Color(0xFFEDF1F5);
}
