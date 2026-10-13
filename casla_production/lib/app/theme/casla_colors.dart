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
  static const Color successOnDark = Color(0xFF65C56B);
  static const Color onDarkSecondary = Color(0xFFB7C1E4);
  static const Color onDarkMuted = Color(0xFF93A0CC);

  // Status — Danger
  static const Color danger = Color(0xFFC62828);
  static const Color dangerBg = Color(0xFFFBEAEA);

  // Phế (defective output): a deep yellow. Kept apart from danger red, so
  // scrap reads as a count to watch rather than as an error.
  static const Color scrap = Color(0xFF9A6B00);
  static const Color scrapBg = Color(0xFFFFF0BF);

  // Status — Pending
  static const Color pending = Color(0xFF85601A);
  static const Color pendingBg = Color(0xFFFBF1DD);

  // Status — Awaiting SAP: entered on this device, not yet posted (held in
  // the sync tab). Violet keeps it apart from posted green and remaining amber.
  static const Color awaiting = Color(0xFF5B3FC4);
  static const Color awaitingBg = Color(0xFFEFEAFB);

  // Status — Carried over: yesterday's unfinished balance moved to today by
  // SAP's overnight REASSIGN job. Teal keeps it apart from new work (navy)
  // and the remaining amber it would otherwise be mistaken for.
  static const Color carryOver = Color(0xFF00695C);
  static const Color carryOverBg = Color(0xFFE0F2F1);

  // Identity bar sub-text
  static const Color identityMeta = Color(0xFFB9C2E4);
  static const Color contextChipText = Color(0xFFDFE4F5);
  static const Color accentLabelDark = Color(0xFFAAB4DD);

  // Banner
  static const Color bannerText = Color(0xFF6B5320);

  static const Color navy100 = Color(0xFFEDF1F5);
}
