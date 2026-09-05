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
  static const Color success = Color(0xFF2E7D32);
  static const Color successBg = Color(0xFFE5F2E6);

  // Status — Danger
  static const Color danger = Color(0xFFC62828);
  static const Color dangerBg = Color(0xFFFBEAEA);

  // Status — Pending
  static const Color pending = Color(0xFF85601A);
  static const Color pendingBg = Color(0xFFFBF1DD);

  // Identity bar sub-text
  static const Color identityMeta = Color(0xFFB9C2E4);
  static const Color contextChipText = Color(0xFFDFE4F5);
  static const Color accentLabelDark = Color(0xFFAAB4DD);

  // Banner
  static const Color bannerText = Color(0xFF6B5320);

  static const Color navy100 = Color(0xFFE8EAF6);
}
