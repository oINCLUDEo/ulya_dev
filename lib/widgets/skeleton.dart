import 'package:flutter/material.dart';

import '../main.dart' show DS;

/// Shimmering placeholder block. Compose several into a layout that mimics
/// the real content while it loads — feels much faster than a spinner.
///
/// One [AnimationController] per [SkeletonTheme] subtree drives every bone,
/// so a whole skeleton screen costs a single ticker.
class SkeletonTheme extends StatefulWidget {
  final Widget child;
  const SkeletonTheme({super.key, required this.child});

  static Animation<double>? _maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SkeletonShimmer>()?.animation;

  @override
  State<SkeletonTheme> createState() => _SkeletonThemeState();
}

class _SkeletonThemeState extends State<SkeletonTheme>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _SkeletonShimmer(animation: _ctrl, child: widget.child);
}

class _SkeletonShimmer extends InheritedWidget {
  final Animation<double> animation;
  const _SkeletonShimmer({required this.animation, required super.child});

  @override
  bool updateShouldNotify(_SkeletonShimmer old) => animation != old.animation;
}

/// A single shimmering "bone".
class SkeletonBone extends StatelessWidget {
  final double width;
  final double height;
  final double radius;
  /// Circle bones ignore [radius].
  final bool circle;

  const SkeletonBone({
    super.key,
    this.width = double.infinity,
    required this.height,
    this.radius = 8,
    this.circle = false,
  });

  @override
  Widget build(BuildContext context) {
    final anim = SkeletonTheme._maybeOf(context);
    if (anim == null) {
      // Used outside a SkeletonTheme — render static.
      return _box(0.5);
    }
    return AnimatedBuilder(
      animation: anim,
      builder: (_, child) {
        // Ease in-out pulse between 35% and 80% brightness.
        final t = anim.value;
        final pulse = 0.35 + 0.45 * (0.5 - 0.5 * (2 * t - 1).abs() * 2).abs();
        return _box(pulse.clamp(0.2, 0.8));
      },
    );
  }

  Widget _box(double opacity) => Container(
        width: circle ? height : width,
        height: height,
        decoration: BoxDecoration(
          color: DS.surface2.withValues(alpha: opacity),
          borderRadius:
              circle ? null : BorderRadius.circular(radius),
          shape: circle ? BoxShape.circle : BoxShape.rectangle,
        ),
      );
}

/// Ready-made skeleton of a server row: flag + two text lines + badge.
/// Matches the real tile metrics so the swap-in doesn't shift layout.
class ServerRowSkeleton extends StatelessWidget {
  const ServerRowSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Row(children: [
        SkeletonBone(width: 36, height: 28, radius: 6),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBone(width: 140, height: 13, radius: 4),
              SizedBox(height: 7),
              SkeletonBone(width: 64, height: 10, radius: 4),
            ],
          ),
        ),
        SizedBox(width: 8),
        SkeletonBone(width: 34, height: 24, radius: 4),
      ]),
    );
  }
}

/// Skeleton of a section header + N server rows.
class ServerSectionSkeleton extends StatelessWidget {
  final int rows;
  const ServerSectionSkeleton({super.key, this.rows = 3});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(2, 14, 2, 10),
          child: Row(children: [
            SkeletonBone(width: 42, height: 42, radius: 12),
            SizedBox(width: 12),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SkeletonBone(width: 120, height: 13, radius: 4),
              SizedBox(height: 6),
              SkeletonBone(width: 180, height: 10, radius: 4),
            ]),
          ]),
        ),
        for (int i = 0; i < rows; i++) const ServerRowSkeleton(),
      ],
    );
  }
}

/// Skeleton of a tariff/plan card (premium page).
class TariffCardSkeleton extends StatelessWidget {
  const TariffCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(DS.radius),
        border: Border.all(color: DS.border),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            SkeletonBone(width: 22, height: 22, circle: true),
            SizedBox(width: 10),
            SkeletonBone(width: 110, height: 14, radius: 4),
            Spacer(),
            SkeletonBone(width: 70, height: 18, radius: 9),
          ]),
          SizedBox(height: 14),
          SkeletonBone(height: 10, radius: 4),
          SizedBox(height: 8),
          SkeletonBone(width: 200, height: 10, radius: 4),
        ],
      ),
    );
  }
}
