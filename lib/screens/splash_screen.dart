// Splash / sign-in gate.

part of '../main.dart';

/// Premium launch screen with subtle fade + scale animation.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _scale = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _controller.forward();
    Future<void>.delayed(const Duration(milliseconds: 2400), _goHome);
  }

  void _navigateTo(Widget screen) {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) => screen,
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 450),
      ),
    );
  }

  Future<void> _goHome() async {
    if (!mounted) return;
    try {
      await AuthService.init();
      try {
        await AppApiKeyService.ensureKey().timeout(const Duration(seconds: 12));
      } catch (e) {
        debugPrint('[Splash] ensureKey skipped: $e');
      }
      await OracleCitadelStore.load();
    } catch (e) {
      debugPrint('[Splash] bootstrap error (continuing): $e');
    }

    if (!mounted) return;

    try {
      if (await AuthService.hasValidSession()) {
        _navigateTo(const MainScreen());
        return;
      }

      final bioOk = await AuthService.tryBiometricUnlock().timeout(
        const Duration(seconds: 15),
        onTimeout: () => false,
      );
      if (bioOk) {
        if (!mounted) return;
        _navigateTo(const MainScreen());
        return;
      }

      final rememberedEmail = await AuthService.getRememberedEmail();
      if (!mounted) return;
      _navigateTo(
        LoginScreen(
          prefillEmail: rememberedEmail,
          onSuccess: (ctx) {
            Navigator.of(ctx).pushReplacement(
              PageRouteBuilder<void>(
                pageBuilder: (_, __, ___) => const MainScreen(),
                transitionsBuilder: (_, animation, __, child) =>
                    FadeTransition(opacity: animation, child: child),
                transitionDuration: const Duration(milliseconds: 450),
              ),
            );
          },
        ),
      );
    } catch (e) {
      debugPrint('[Splash] route error (fallback login): $e');
      if (!mounted) return;
      _navigateTo(
        LoginScreen(
          onSuccess: (ctx) {
            Navigator.of(ctx).pushReplacement(
              PageRouteBuilder<void>(
                pageBuilder: (_, __, ___) => const MainScreen(),
                transitionsBuilder: (_, animation, __, child) =>
                    FadeTransition(opacity: animation, child: child),
                transitionDuration: const Duration(milliseconds: 450),
              ),
            );
          },
        ),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      body: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (_, child) => Opacity(
            opacity: _fade.value,
            child: Transform.scale(scale: _scale.value, child: child),
          ),
          child: const AppLogo(height: 220, alignment: Alignment.center),
        ),
      ),
    );
  }
}
