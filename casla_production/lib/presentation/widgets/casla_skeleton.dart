import 'package:flutter/material.dart';

import '../../app/theme/casla_colors.dart';

/// Lightweight loading placeholder that keeps the final layout stable while
/// data is loading. The shimmer is intentionally subtle and uses a single
/// animated decoration, so it remains reasonable on older PDAs.
class CaslaSkeleton extends StatefulWidget {
  final double? width;
  final double height;
  final double radius;

  const CaslaSkeleton({
    super.key,
    this.width,
    required this.height,
    this.radius = 10,
  });

  @override
  State<CaslaSkeleton> createState() => _CaslaSkeletonState();
}

class _CaslaSkeletonState extends State<CaslaSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (disableAnimations) {
      return Opacity(
        opacity: 0.72,
        child: _placeholder(color: CaslaColors.muted100),
      );
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final shift = -1.4 + (_controller.value * 2.8);
        return _placeholder(
          gradient: LinearGradient(
            begin: Alignment(shift, 0),
            end: Alignment(shift + 1.1, 0),
            colors: const [
              CaslaColors.muted100,
              CaslaColors.muted100,
              Color(0xFFFFFFFF),
              CaslaColors.muted100,
              CaslaColors.muted100,
            ],
            stops: const [0, 0.26, 0.5, 0.74, 1],
          ),
        );
      },
    );
  }

  Widget _placeholder({Color? color, Gradient? gradient}) {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: color,
        gradient: gradient,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
    );
  }
}
