// Shared spacing, animations, section headers, empty states, logo.

part of '../main.dart';

abstract final class _AppSpacing {
  static const double screen = 20;
  static const double section = 24;
  static const double card = 16;
  static const double item = 12;
}

/// Scroll + min-height fill for Analyze / Trade Setup tab forms (removes empty bottom void).
Widget _premiumTabScrollBody({
  required double minHeight,
  required List<Widget> children,
}) {
  return SingleChildScrollView(
    physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center,
          children: children,
        ),
      ),
    ),
  );
}

Route<T> _premiumPageRoute<T>(WidgetBuilder builder) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curve = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curve,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.035), end: Offset.zero).animate(curve),
          child: child,
        ),
      );
    },
    transitionDuration: const Duration(milliseconds: 320),
  );
}

class _FadeIn extends StatefulWidget {
  final Widget child;
  final Duration delay;
  final Duration duration;

  const _FadeIn({
    required this.child,
    this.delay = Duration.zero,
  }) : duration = const Duration(milliseconds: 420);

  @override
  State<_FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<_FadeIn> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    Future<void>.delayed(widget.delay, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.03), end: Offset.zero).animate(curve),
        child: widget.child,
      ),
    );
  }
}

class _ScaleTap extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  const _ScaleTap({required this.child, this.onTap});

  @override
  State<_ScaleTap> createState() => _ScaleTapState();
}

class _ScaleTapState extends State<_ScaleTap> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null ? null : (_) => setState(() => _pressed = true),
      onTapUp: widget.onTap == null ? null : (_) => setState(() => _pressed = false),
      onTapCancel: widget.onTap == null ? null : () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const _SectionHeader({required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: _AppSpacing.item),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.2),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _AppEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;
  /// When true, sizes down and centers within a bounded parent (avoids overflow).
  final bool fitHeight;

  const _AppEmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
    this.fitHeight = false,
  });

  Widget _buildContent({required bool compact}) {
    const accent = Color(0xFF00BFFF);
    final outerSize = compact ? 84.0 : 112.0;
    final innerSize = compact ? 58.0 : 76.0;
    final iconSize = compact ? 28.0 : 34.0;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 28, vertical: compact ? 8 : 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Container(
                width: outerSize,
                height: outerSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withValues(alpha: 0.05),
                  border: Border.all(color: accent.withValues(alpha: 0.08)),
                ),
              ),
              Container(
                width: innerSize,
                height: innerSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      accent.withValues(alpha: 0.22),
                      accent.withValues(alpha: 0.06),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.12),
                      blurRadius: compact ? 16 : 24,
                      spreadRadius: compact ? 1 : 2,
                    ),
                  ],
                ),
                child: Icon(icon, size: iconSize, color: accent.withValues(alpha: 0.95)),
              ),
              if (!compact) ...[
                Positioned(
                  top: -4,
                  right: -8,
                  child: Icon(Icons.auto_awesome, size: 16, color: Colors.amber.withValues(alpha: 0.55)),
                ),
                Positioned(
                  bottom: 2,
                  left: -10,
                  child: Icon(Icons.circle, size: 8, color: accent.withValues(alpha: 0.35)),
                ),
              ],
            ],
          ),
          SizedBox(height: compact ? 14 : 22),
          Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 15 : 17,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
            ),
          ),
          SizedBox(height: compact ? 6 : 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            maxLines: compact ? 3 : 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: compact ? 13 : 14, height: 1.4, color: Colors.grey[500]),
          ),
          if (action != null) ...[
            SizedBox(height: compact ? 12 : 20),
            action!,
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!fitHeight) {
      return Center(child: _buildContent(compact: false));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 260;
        return SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(child: _buildContent(compact: compact)),
          ),
        );
      },
    );
  }
}

ThemeData _buildAppTheme() {
  const accent = Color(0xFF00BFFF);
  const surface = Color(0xFF1A1A1A);
  const scaffold = Color(0xFF0F0F0F);

  return ThemeData.dark().copyWith(
    primaryColor: accent,
    scaffoldBackgroundColor: scaffold,
    colorScheme: const ColorScheme.dark(
      primary: accent,
      surface: surface,
      onSurface: Colors.white,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: scaffold,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: Colors.white,
        letterSpacing: -0.3,
      ),
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
      ),
    ),
    dividerTheme: DividerThemeData(color: Colors.white.withValues(alpha: 0.06), thickness: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: accent, width: 1.2),
      ),
      labelStyle: TextStyle(color: Colors.grey[500]),
      hintStyle: TextStyle(color: Colors.grey[600]),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, letterSpacing: 0.1),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
    ),
    textTheme: const TextTheme(
      bodyMedium: TextStyle(fontSize: 15, height: 1.5),
      bodyLarge: TextStyle(fontSize: 16, height: 1.55),
    ),
  );
}

/// Reusable app logo — scales cleanly for AppBar, splash, and profile headers.
class AppLogo extends StatelessWidget {
  final double height;
  final Alignment alignment;

  const AppLogo({
    super.key,
    this.height = 40,
    this.alignment = Alignment.centerLeft,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Image.asset(
        kAppLogoAsset,
        height: height,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        errorBuilder: (_, __, ___) => Text(
          'On-Chain Oracle',
          style: TextStyle(
            fontSize: height * 0.38,
            fontWeight: FontWeight.w700,
            color: Colors.grey[200],
          ),
        ),
      ),
    );
  }
}
