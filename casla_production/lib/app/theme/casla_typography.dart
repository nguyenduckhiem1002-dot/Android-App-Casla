// Casla Group Design System — Typography
// Spec: Section 6.2
// Fonts: Manrope (display), Inter (body), IBM Plex Mono (mono)
// Minimum 14sp on PDA devices

import 'package:flutter/material.dart';
import 'casla_colors.dart';

class CaslaTypography {
  CaslaTypography._();

  // Font families (spec uses Manrope for display, Inter for body)
  static const String fontDisplay = 'Manrope';
  static const String fontBody = 'Inter';

  /// Display Number — KPI chính (32-36sp / 700)
  static const TextStyle displayNumber = TextStyle(
    fontFamily: fontDisplay,
    fontWeight: FontWeight.w800,
    fontSize: 34,
    height: 1.1,
    color: CaslaColors.primaryNavy,
  );

  /// Screen Title (22-24sp / 700)
  static const TextStyle screenTitle = TextStyle(
    fontFamily: fontDisplay,
    fontWeight: FontWeight.w800,
    fontSize: 22,
    height: 1.25,
    color: CaslaColors.primaryNavy,
  );

  /// Section Title (18-20sp / 600)
  static const TextStyle sectionTitle = TextStyle(
    fontFamily: fontDisplay,
    fontWeight: FontWeight.w800,
    fontSize: 14,
    height: 1.3,
    letterSpacing: 0.2,
    color: CaslaColors.primaryNavy,
  );

  /// Body (16-18sp / 400)
  static const TextStyle body = TextStyle(
    fontWeight: FontWeight.w400,
    fontSize: 16,
    height: 1.4,
    color: CaslaColors.primaryNavy,
  );

  /// Body Medium (14-16sp / 500)
  static const TextStyle bodyMedium = TextStyle(
    fontWeight: FontWeight.w500,
    fontSize: 14,
    height: 1.4,
    color: CaslaColors.primaryNavy,
  );

  /// Label (14-16sp / 600)
  static const TextStyle label = TextStyle(
    fontWeight: FontWeight.w700,
    fontSize: 14.5,
    color: CaslaColors.primaryNavy,
  );

  /// Caption / Mono (14sp / 400)
  static const TextStyle caption = TextStyle(
    fontFamily: 'monospace',
    fontWeight: FontWeight.w600,
    fontSize: 11,
    height: 1.4,
    color: CaslaColors.muted,
  );

  /// Identity Name
  static const TextStyle identityName = TextStyle(
    fontFamily: fontDisplay,
    fontWeight: FontWeight.w800,
    fontSize: 17,
    color: Colors.white,
  );

  /// Identity Meta
  static const TextStyle identityMeta = TextStyle(
    fontFamily: 'Inter',
    fontWeight: FontWeight.w500,
    fontSize: 12.5,
    color: CaslaColors.identityMeta,
  );

  /// KPI Label
  static const TextStyle kpiLabel = TextStyle(
    fontWeight: FontWeight.w600,
    fontSize: 11,
    letterSpacing: 0.2,
    color: CaslaColors.muted,
  );

  /// KPI Value
  static const TextStyle kpiValue = TextStyle(
    fontFamily: fontDisplay,
    fontWeight: FontWeight.w800,
    fontSize: 26,
    height: 1.0,
    color: CaslaColors.primaryNavy,
  );

  /// Order Code (mono)
  static const TextStyle orderCode = TextStyle(
    fontFamily: 'monospace',
    fontWeight: FontWeight.w600,
    fontSize: 11.5,
    letterSpacing: 0.3,
    color: CaslaColors.muted,
  );

  /// Order Name
  static const TextStyle orderName = TextStyle(
    fontFamily: fontDisplay,
    fontWeight: FontWeight.w700,
    fontSize: 14.5,
    color: CaslaColors.primaryNavy,
  );

  /// Stat label
  static const TextStyle statLabel = TextStyle(
    fontWeight: FontWeight.w600,
    fontSize: 11,
    color: CaslaColors.muted,
  );

  /// Stat value
  static const TextStyle statValue = TextStyle(
    fontFamily: fontDisplay,
    fontWeight: FontWeight.w800,
    fontSize: 15,
    color: CaslaColors.primaryNavy,
  );

  /// Quantity display (large)
  static const TextStyle quantityDisplay = TextStyle(
    fontFamily: fontDisplay,
    fontWeight: FontWeight.w800,
    fontSize: 52,
    color: CaslaColors.primaryNavy,
  );

  /// Chip text (mono)
  static const TextStyle chipText = TextStyle(
    fontFamily: 'monospace',
    fontWeight: FontWeight.w700,
    fontSize: 10.5,
    letterSpacing: 0.3,
  );

  /// Button text
  static const TextStyle button = TextStyle(
    fontWeight: FontWeight.w700,
    fontSize: 14.5,
  );

  /// Subheader title
  static const TextStyle subheaderTitle = TextStyle(
    fontFamily: fontDisplay,
    fontWeight: FontWeight.w700,
    fontSize: 16.5,
    color: Colors.white,
  );

  /// Subheader subtitle (mono)
  static const TextStyle subheaderSub = TextStyle(
    fontFamily: 'monospace',
    fontWeight: FontWeight.w500,
    fontSize: 10.5,
    color: CaslaColors.identityMeta,
  );
}
