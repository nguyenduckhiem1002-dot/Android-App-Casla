import 'package:flutter/material.dart';
import '../../app/theme/casla_colors.dart';

class CaslaSkeleton extends StatefulWidget {
  final double width;
  final double height;
  final double borderRadius;

  const CaslaSkeleton({
    super.key,
    required this.width,
    required this.height,
    this.borderRadius = 8,
  });

  @override
  State<CaslaSkeleton> createState() => _CaslaSkeletonState();
}

class _CaslaSkeletonState extends State<CaslaSkeleton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _animation = Tween<double>(begin: 0.35, end: 0.85).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: CaslaColors.line.withValues(alpha: _animation.value),
            borderRadius: BorderRadius.circular(widget.borderRadius),
          ),
        );
      },
    );
  }
}

class CaslaCardSkeleton extends StatelessWidget {
  const CaslaCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: const [
                CaslaSkeleton(width: 120, height: 16, borderRadius: 4),
                CaslaSkeleton(width: 60, height: 20, borderRadius: 10),
              ],
            ),
            const SizedBox(height: 12),
            const CaslaSkeleton(width: double.infinity, height: 14, borderRadius: 4),
            const SizedBox(height: 8),
            const CaslaSkeleton(width: 180, height: 14, borderRadius: 4),
          ],
        ),
      ),
    );
  }
}
