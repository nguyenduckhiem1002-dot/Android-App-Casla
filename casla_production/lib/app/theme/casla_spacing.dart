/// Casla Group Design System — spacing, radius and type scales.
///
/// These exist because the screens had drifted into twelve different corner
/// radii and twenty-four font sizes, including half-point steps that came from
/// nudging one widget at a time until it fit. Everything new picks from here.
library;

abstract final class CaslaSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 28;
  static const double xxl = 36;
}

abstract final class CaslaRadius {
  /// Inputs, number-pad keys, small tiles.
  static const double sm = 8;

  /// The default. Cards, buttons, sheets, panels.
  static const double md = 12;

  /// Emphasis surfaces: KPI tiles, the shift context card, hero panels.
  static const double lg = 16;

  /// Chips and anything that should read as fully rounded.
  static const double pill = 999;
}

/// Type scale.
///
/// [caption] is a hard floor. The old screens went down to 9.5sp, which is not
/// readable on a 4.7" handset held at arm's length, under shop-floor lighting,
/// by an operator who may be wearing safety glasses.
abstract final class CaslaType {
  static const double caption = 12;
  static const double body = 14;
  static const double subtitle = 16;
  static const double title = 20;
  static const double display = 26;

  /// The single largest readout on a screen, such as the quantity being
  /// confirmed. Never used for more than one element at a time.
  static const double hero = 40;
}
