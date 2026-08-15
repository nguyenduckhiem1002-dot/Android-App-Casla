// Casla Group Design System — SVG Brand Logo Component
// Supports both Light background (logo.svg) and Dark background (logo-white.svg)
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class CaslaLogo extends StatelessWidget {
  final double height;
  final double? width;
  final bool isDarkBackground;
  final String? subtitle;
  final Color textColor;
  final Color? color;

  const CaslaLogo({
    super.key,
    double? height,
    this.width,
    double? size,
    this.isDarkBackground = false,
    this.subtitle,
    this.textColor = const Color(0xFF16234A),
    this.color,
  }) : height = size ?? height ?? 56;

  /// Raw SVG fallback for logo.svg (Light Background: Navy #243B74 + Gold #C39D56)
  static const String _rawLogoSvg = '''<?xml version="1.0" encoding="utf-8"?>
<svg version="1.1" id="Layer_1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" x="0px" y="0px"
	 width="300px" height="150px" viewBox="0 0 300 150" style="enable-background:new 0 0 300 150;" xml:space="preserve">
<path style="fill:#243B74;" d="M54.7,83.8C49.2,90.7,41.5,94,33.5,94C18.7,94,6.9,82.7,6.9,68.1s11.8-25.9,26.7-25.9c7.9,0,15.7,3.2,21.2,10.2
	l-7.6,5.7c-3.2-4.6-8-7.2-13.6-7.2c-8.9,0-17,7.5-17,17.2s8.1,17.2,17,17.2c5.6,0,10.6-2.6,13.8-6.9L54.7,83.8z"/>
<path style="fill:#243B74;" d="M135.8,78.6c3.7,4,8.9,6.7,14.7,6.7c7-0.1,11.9-2.7,11.9-7.4c0-11.1-32-0.4-32-20.6c0-8.9,9.3-14.9,20.6-14.9
	c8.2,0,14.9,2.6,19.8,7.6l-6.8,6.1c-4.5-4.4-8.6-5.9-13.4-5.9c-7.6,0-10.4,3.7-10.4,6.7c0,11.2,32,0,32,20.6
	c0,10.4-10.5,16.6-21.9,16.6c-7,0-15-2.6-21.3-9.2L135.8,78.6z"/>
<polygon style="fill:#243B74;" points="213.8,84.3 194.3,84.3 194.3,43.3 185.1,43.3 185.1,93 223,93 223,84.3 "/>
<polygon style="fill:#243B74;" points="245.3,93 264.9,59.1 284.4,93 295.1,93 264.9,40.6 234.7,93 "/>
<g>
	<polygon style="fill:#C39D56;" points="71.8,93 91.4,59.1 110.9,93 121.6,93 91.4,40.6 61.2,93 	"/>
	<path style="fill:#C39D56;" d="M91.4,38.1c1.2-7.7,4.6-12.1,11.3-14.5C96.1,21.1,92.6,16.7,91.4,9c-1.2,7.6-4.7,12.1-11.5,14.5
		C86.7,25.9,90.3,30.5,91.4,38.1z"/>
</g>
</svg>''';

  /// Raw SVG fallback for logo-white.svg (Dark Background: White #FFFFFF + Gold #C39C56)
  static const String _rawWhiteSvg = '''<?xml version="1.0" encoding="utf-8"?>
<svg version="1.1" id="Layer_1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" x="0px" y="0px"
width="300px" height="150px" viewBox="0 0 300 150" style="enable-background:new 0 0 300 150;" xml:space="preserve">
<path style="fill:#FFFFFF;" d="M54.7,83.8C49.2,90.7,41.5,94,33.5,94C18.7,94,6.9,82.7,6.9,68.1s11.8-25.9,26.7-25.9
c7.9,0,15.7,3.2,21.2,10.2l-7.6,5.7c-3.2-4.6-8-7.2-13.6-7.2c-8.9,0-17,7.5-17,17.2s8.1,17.2,17,17.2c5.6,0,10.6-2.6,13.8-6.9
L54.7,83.8z"/>
<path style="fill:#FFFFFF;" d="M135.8,78.6c3.7,4,8.9,6.7,14.7,6.7c7-0.1,11.9-2.7,11.9-7.4c0-11.1-32-0.4-32-20.6
c0-8.9,9.3-14.9,20.6-14.9c8.2,0,14.9,2.6,19.8,7.6l-6.8,6.1c-4.5-4.4-8.6-5.9-13.4-5.9c-7.6,0-10.4,3.7-10.4,6.7
c0,11.2,32,0,32,20.6c0,10.4-10.5,16.6-21.9,16.6c-7,0-15-2.6-21.3-9.2L135.8,78.6z"/>
<polygon style="fill:#FFFFFF;" points="213.8,84.3 194.3,84.3 194.3,43.3 185.1,43.3 185.1,93 223,93 223,84.3 "/>
<polygon style="fill:#FFFFFF;" points="245.3,93 264.9,59.1 284.4,93 295.1,93 264.9,40.6 234.7,93 "/>
<g>
<polygon style="fill:#C39C56;" points="71.8,93 91.4,59.1 110.9,93 121.6,93 91.4,40.6 61.2,93 	"/>
<path style="fill:#C39C56;" d="M91.4,38.1c1.2-7.7,4.6-12.1,11.3-14.5C96.1,21.1,92.6,16.7,91.4,9c-1.2,7.6-4.7,12.1-11.5,14.5
C86.7,25.9,90.3,30.5,91.4,38.1z"/>
</g>
</svg>''';

  @override
  Widget build(BuildContext context) {
    final assetPath = isDarkBackground
        ? 'assets/images/logo_white.svg'
        : 'assets/images/logo.svg';
    final fallbackSvg = isDarkBackground ? _rawWhiteSvg : _rawLogoSvg;
    final colorFilter = color != null
        ? ColorFilter.mode(color!, BlendMode.srcIn)
        : null;

    final Widget logoWidget = SvgPicture.asset(
      assetPath,
      height: height,
      width: width,
      fit: BoxFit.contain,
      colorFilter: colorFilter,
      placeholderBuilder: (context) => SvgPicture.string(
        fallbackSvg,
        height: height,
        width: width,
        fit: BoxFit.contain,
        colorFilter: colorFilter,
      ),
    );

    if (subtitle == null) {
      return logoWidget;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        logoWidget,
        const SizedBox(height: 4),
        Text(
          subtitle!,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w500,
            fontSize: height * 0.25,
            color: textColor,
          ),
        ),
      ],
    );
  }
}

/// Backward compatible alias for CaslaLogoWhite
class CaslaLogoWhite extends StatelessWidget {
  final double height;
  final double? width;
  final String? subtitle;
  final Color textColor;
  final Color? color;

  const CaslaLogoWhite({
    super.key,
    double? height,
    this.width,
    double? size,
    this.subtitle,
    this.textColor = Colors.white,
    this.color,
  }) : height = size ?? height ?? 48;

  @override
  Widget build(BuildContext context) {
    return CaslaLogo(
      height: height,
      width: width,
      isDarkBackground: true,
      subtitle: subtitle,
      textColor: textColor,
      color: color,
    );
  }
}
