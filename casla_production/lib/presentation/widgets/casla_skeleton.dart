import 'package:flutter/material.dart';

import '../../app/theme/casla_colors.dart';

/// Lightweight loading placeholder that keeps the final layout stable while
/// data is loading. It uses only opacity, so it remains cheap on older PDAs.
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
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _opacity = Tween<double>(
      begin: 0.45,
      end: 0.9,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final child = Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: CaslaColors.muted100,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
    );
    return disableAnimations
        ? Opacity(opacity: 0.72, child: child)
        : FadeTransition(opacity: _opacity, child: child);
  }
}
