import 'package:flutter/material.dart';

import 'profile_avatar.dart';

/// Bottom clearance above main tab bar (Home, Analyze, Trade Setup, Charts, Portfolio).
const double kMainTabBottomClearance = 80;

/// Full-screen crystal ball / oracle branding behind Profile & Account.
class OracleProfileBackdrop extends StatelessWidget {
  final double orbHeight;
  final double orbOpacity;
  /// When true, centers an enlarged orb (Profile screen). Default is top-aligned (Account, etc.).
  final bool centeredOrb;

  const OracleProfileBackdrop({
    super.key,
    this.orbHeight = 220,
    this.orbOpacity = 0.16,
    this.centeredOrb = false,
  });

  static const String _logoAsset = 'assets/images/app_logo.png';
  static const String _iconAsset = 'assets/images/app_icon.png';

  @override
  Widget build(BuildContext context) {
    final orb = Opacity(
      opacity: orbOpacity,
      child: Image.asset(
        _logoAsset,
        height: orbHeight,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        errorBuilder: (_, __, ___) => Image.asset(
          _iconAsset,
          height: orbHeight * 0.9,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
        ),
      ),
    );

    // Premium Profile hero backdrop — deep black only, no teal/blue wash.
    if (centeredOrb) {
      return IgnorePointer(
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0xFF0F0F0F)),
            Align(
              alignment: const Alignment(0, -0.72),
              child: orb,
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      const Color(0xFF0F0F0F).withValues(alpha: 0.18),
                      const Color(0xFF0F0F0F).withValues(alpha: 0.08),
                      const Color(0xFF0F0F0F).withValues(alpha: 0.38),
                      const Color(0xFF0F0F0F).withValues(alpha: 0.72),
                    ],
                    stops: const [0.0, 0.32, 0.58, 1.0],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.55),
                    radius: 0.92,
                    colors: [
                      Colors.transparent,
                      const Color(0xFF0F0F0F).withValues(alpha: 0.28),
                    ],
                    stops: const [0.42, 1.0],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF0F0F0F),
              gradient: RadialGradient(
                center: const Alignment(0, -0.35),
                radius: 1.1,
                colors: [
                  const Color(0xFF00BFFF).withValues(alpha: 0.08),
                  const Color(0xFF0F0F0F),
                ],
              ),
            ),
          ),
          Positioned(
            top: -40,
            left: 0,
            right: 0,
            child: Center(child: orb),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    const Color(0xFF0F0F0F).withValues(alpha: 0.5),
                    const Color(0xFF0F0F0F),
                  ],
                  stops: const [0.35, 0.72, 1.0],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Brand orb watermark inside cards (legacy helper).
class OracleOrbBackground extends StatelessWidget {
  final Widget child;
  final bool heroMode;
  final double orbOpacity;
  final EdgeInsets padding;

  const OracleOrbBackground({
    super.key,
    required this.child,
    this.heroMode = false,
    this.orbOpacity = 0.18,
    this.padding = EdgeInsets.zero,
  });

  static const String _logoAsset = 'assets/images/app_logo.png';
  static const String _iconAsset = 'assets/images/app_icon.png';

  @override
  Widget build(BuildContext context) {
    final orbHeight = heroMode ? 160.0 : 120.0;

    // StackFit.loose — safe inside ListView/scrollables (expand causes unbounded height errors).
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.topCenter,
        children: [
          Positioned(
            top: heroMode ? -16 : -8,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: Opacity(
                  opacity: orbOpacity,
                  child: Image.asset(
                    _logoAsset,
                    height: orbHeight,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                    errorBuilder: (_, __, ___) => Image.asset(
                      _iconAsset,
                      height: orbHeight * 0.85,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (heroMode)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        const Color(0xFF1A1A1A).withValues(alpha: 0.85),
                        const Color(0xFF1A1A1A),
                      ],
                      stops: const [0.0, 0.45, 1.0],
                    ),
                  ),
                ),
              ),
            ),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

/// Hero card with prominent oracle logo + readable text overlay.
class OracleOrbHeroCard extends StatelessWidget {
  final String displayName;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final String? profileImagePath;

  const OracleOrbHeroCard({
    super.key,
    required this.displayName,
    required this.subtitle,
    this.onTap,
    this.trailing,
    this.profileImagePath,
  });

  @override
  Widget build(BuildContext context) {
    final content = Card(
      clipBehavior: Clip.antiAlias,
      child: OracleOrbBackground(
        heroMode: true,
        orbOpacity: 0.2,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ProfileAvatarImage(
              size: 72,
              imagePath: profileImagePath,
              circular: false,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    displayName,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 13, color: Colors.grey[400]),
                  ),
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );

    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: content,
    );
  }
}

/// SafeArea + bottom inset for tab screens (Portfolio) or pushed routes.
class AppScreenBody extends StatelessWidget {
  final Widget child;
  final bool includeBottomNav;
  final EdgeInsetsGeometry? padding;

  const AppScreenBody({
    super.key,
    required this.child,
    this.includeBottomNav = false,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final base = padding ?? const EdgeInsets.all(20);
    final bottomExtra = includeBottomNav ? kMainTabBottomClearance : 20.0;
    final resolved = base.resolve(Directionality.of(context));
    final inset = MediaQuery.paddingOf(context);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          resolved.left,
          resolved.top,
          resolved.right,
          resolved.bottom + inset.bottom + bottomExtra,
        ),
        child: child,
      ),
    );
  }
}

/// Padding for root tab screens so content clears the bottom navigation bar.
class TabRootBody extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;

  const TabRootBody({super.key, required this.child, this.padding});

  static EdgeInsets resolvedPadding(BuildContext context) {
    final inset = MediaQuery.paddingOf(context);
    return EdgeInsets.fromLTRB(
      20,
      12,
      20,
      20 + inset.bottom + kMainTabBottomClearance,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: padding ?? resolvedPadding(context),
        child: child,
      ),
    );
  }
}

/// Extra bottom padding for full-screen scroll reports (analysis / trade setup results).
double reportScrollBottomInset(BuildContext context) {
  return MediaQuery.paddingOf(context).bottom + 28;
}
