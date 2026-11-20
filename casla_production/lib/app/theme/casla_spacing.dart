/// Casla Group Design System — spacing, radius and type scales.
///
/// These exist because the screens had drifted into twelve different corner
/// radii and twenty-four font sizes, including half-point steps that came from
/// nudging one widget at a time until it fit. Everything new picks from here.
library;

import 'package:flutter/material.dart';

abstract final class CaslaSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 28;
  static const double xxl = 36;
}

/// Popups (dialogs). They had drifted into five side gaps (40, 24, 20, 16 px)
/// and four inner paddings: every popup now takes these, so they all have the
/// same width on a phone and the same room inside.
abstract final class CaslaDialog {
  /// Gap between the popup and each side of the screen: the popup takes
  /// about 94% of a phone's width, as the supervisors asked. At 1.5 it ran
  /// edge to edge and looked too big.
  static const double sideGap = 12;

  /// Every popup is this wide, or as wide as the screen allows after
  /// [sideGap]. Without it a popup with a short message shrinks to its text
  /// and floats in the middle; this cap only shows on a landscape screen.
  static const double width = 560;

  /// Gap above and below the popup.
  static const double topBottomGap = 24;

  /// Room on the left and right inside the popup.
  static const double padding = 19;

  /// Room above the title and below the buttons.
  static const double verticalPadding = 19;

  /// Corner radius of every popup, the date picker included. They had drifted
  /// into 18, 20, 24 and Flutter's 28.
  static const double radius = CaslaRadius.lg;

  /// Size of every popup title. Flutter's default is 24, and the popups had
  /// drifted into 16, 18 and 20.
  static const double titleSize = 20;

  /// Body text of a popup and its line height. The supervisors include older
  /// people reading a PDA at arm's length: 15 px with room between lines.
  static const double bodySize = 15;
  static const double lineHeight = 1.5;

  /// Quantities in a popup are read before anything else, by people who may
  /// not see well: always bold, a step above the body text, and the total
  /// the largest figure of the popup.
  static const double figureSize = 17;
  static const double tileFigureSize = 22;
  static const double totalSize = 26;

  /// Gap between the title and the faint line under it.
  static const double headerGap = 14;

  /// Height of every popup button: a full tap target at a glance.
  static const double buttonHeight = 48;

  /// Size and weight of the popup buttons. Merged into a button's own style,
  /// so a colour set by the popup stays. A button's text style is not merged
  /// with the theme, so it names the theme's family (Roboto on Android).
  static const ButtonStyle actionStyle = ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(64, buttonHeight)),
    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 20)),
    textStyle: WidgetStatePropertyAll(
      TextStyle(
        fontFamily: 'Roboto',
        fontSize: 15,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  // AlertDialog takes its title, icon and content padding from its own
  // arguments, not from the theme, so each popup passes these.
  static const EdgeInsets iconPadding = EdgeInsets.fromLTRB(
    padding,
    verticalPadding,
    padding,
    10,
  );
  static const EdgeInsets titlePadding = EdgeInsets.fromLTRB(
    padding,
    verticalPadding,
    padding,
    0,
  );
  static const EdgeInsets contentPadding = EdgeInsets.fromLTRB(
    padding,
    headerGap,
    padding,
    verticalPadding,
  );
  static const EdgeInsets actionsPadding = EdgeInsets.fromLTRB(
    padding,
    0,
    padding,
    verticalPadding,
  );
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
