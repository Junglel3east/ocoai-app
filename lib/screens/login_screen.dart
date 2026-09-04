import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import '../services/auth_service.dart';

typedef LoginSuccessCallback = void Function(BuildContext context);

/// Dark premium login — email/password, remember me, and biometric unlock.
class LoginScreen extends StatefulWidget {
  final LoginSuccessCallback onSuccess;
  final String? prefillEmail;

  const LoginScreen({
    super.key,
    required this.onSuccess,
    this.prefillEmail,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _rememberMe = true;
  bool _enableBiometric = false;
  bool _isCreateMode = false;
  bool _obscurePassword = true;
  bool _loading = false;
  bool _biometricAvailable = false;
  bool _hasAccount = false;
  String _biometricLabel = 'Biometric Login';
  List<BiometricType> _biometricTypes = const [];

  @override
  void initState() {
    super.initState();
    if (widget.prefillEmail != null) {
      _emailController.text = widget.prefillEmail!;
    }
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final hasAccount = await AuthService.hasRegisteredAccount();
    final canBio = await AuthService.canUseBiometrics();
    final types = await AuthService.availableBiometricTypes();
    final remembered = await AuthService.getRememberedEmail();
    final bioEnabled = await AuthService.isBiometricEnabled();

    if (!mounted) return;
    setState(() {
      _hasAccount = hasAccount;
      _isCreateMode = !hasAccount;
      _biometricAvailable = canBio;
      _biometricTypes = types;
      _biometricLabel = AuthService.biometricLabel(types);
      _enableBiometric = bioEnabled && canBio;
      if (remembered != null && _emailController.text.isEmpty) {
        _emailController.text = remembered;
        _rememberMe = true;
      }
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);
    try {
      final email = _emailController.text.trim();
      final password = _passwordController.text.trim();

      final AuthResult result;
      if (_isCreateMode) {
        result = await AuthService.signUp(
          email: email,
          password: password,
          rememberMe: _rememberMe,
          enableBiometric: _enableBiometric,
        );
      } else {
        result = await AuthService.signIn(
          email: email,
          password: password,
          rememberMe: _rememberMe,
          enableBiometric: _enableBiometric,
        );
      }

      if (!mounted) return;
      if (result.ok) {
        widget.onSuccess(context);
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.message ?? 'Authentication failed.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Sign in failed. If you reinstalled the app, tap "Create one" to register again.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _biometricLogin() async {
    setState(() => _loading = true);
    final result = await AuthService.signInWithBiometrics();
    if (!mounted) return;
    setState(() => _loading = false);

    if (result.ok) {
      widget.onSuccess(context);
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.message ?? 'Biometric sign-in failed.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0E),
      body: Stack(
        children: [
          Positioned(
            top: -120,
            left: -80,
            child: Container(
              width: 280,
              height: 280,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF00BFFF).withValues(alpha: 0.18),
                    blurRadius: 80,
                    spreadRadius: 20,
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            bottom: -100,
            right: -60,
            child: Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF7C4DFF).withValues(alpha: 0.12),
                    blurRadius: 70,
                    spreadRadius: 10,
                  ),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.fromLTRB(28, 24, 28, 24 + bottomInset),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: Image.asset(
                            'assets/images/app_logo.png',
                            height: 88,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Text(
                              'On-Chain Oracle AI',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 28),
                        Text(
                          _isCreateMode ? 'Create Account' : 'Welcome Back',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.4,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _isCreateMode
                              ? 'Secure your edge with an Oracle account'
                              : 'Sign in to access your command center',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 14, height: 1.4, color: Colors.grey[500]),
                        ),
                        const SizedBox(height: 32),
                        _LoginField(
                          controller: _emailController,
                          label: 'Email',
                          icon: Icons.mail_outline_rounded,
                          keyboardType: TextInputType.emailAddress,
                          validator: (v) {
                            final t = v?.trim() ?? '';
                            if (t.isEmpty) return 'Email is required';
                            if (!t.contains('@') || !t.contains('.')) return 'Enter a valid email';
                            return null;
                          },
                        ),
                        const SizedBox(height: 14),
                        _LoginField(
                          controller: _passwordController,
                          label: 'Password',
                          icon: Icons.lock_outline_rounded,
                          obscure: _obscurePassword,
                          suffix: IconButton(
                            icon: Icon(
                              _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                              size: 20,
                              color: Colors.grey[500],
                            ),
                            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                          ),
                          validator: (v) {
                            final t = v ?? '';
                            if (t.isEmpty) return 'Password is required';
                            if (_isCreateMode && t.length < 8) {
                              return 'Use at least 8 characters';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            SizedBox(
                              width: 24,
                              height: 24,
                              child: Checkbox(
                                value: _rememberMe,
                                activeColor: const Color(0xFF00BFFF),
                                side: BorderSide(color: Colors.grey[600]!),
                                onChanged: (v) {
                                  setState(() {
                                    _rememberMe = v ?? false;
                                    if (!_rememberMe) _enableBiometric = false;
                                  });
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text('Remember me', style: TextStyle(fontSize: 14, color: Colors.grey[400])),
                          ],
                        ),
                        if (_biometricAvailable && _rememberMe) ...[
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              SizedBox(
                                width: 24,
                                height: 24,
                                child: Checkbox(
                                  value: _enableBiometric,
                                  activeColor: const Color(0xFF00E676),
                                  side: BorderSide(color: Colors.grey[600]!),
                                  onChanged: (v) => setState(() => _enableBiometric = v ?? false),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Enable $_biometricLabel',
                                  style: TextStyle(fontSize: 14, color: Colors.grey[400]),
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: _loading ? null : _submit,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF00BFFF),
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                          child: _loading
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                                )
                              : Text(
                                  _isCreateMode ? 'Create Account' : 'Sign In',
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                                ),
                        ),
                        if (_biometricAvailable && _hasAccount && _rememberMe) ...[
                          const SizedBox(height: 14),
                          OutlinedButton.icon(
                            onPressed: _loading ? null : _biometricLogin,
                            icon: Icon(
                              _biometricTypes.contains(BiometricType.face)
                                  ? Icons.face_rounded
                                  : Icons.fingerprint_rounded,
                              color: const Color(0xFF00E676),
                            ),
                            label: Text('Sign in with $_biometricLabel'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF00E676),
                              side: BorderSide(color: const Color(0xFF00E676).withValues(alpha: 0.45)),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        Center(
                          child: TextButton(
                            onPressed: _hasAccount
                                ? () => setState(() => _isCreateMode = !_isCreateMode)
                                : null,
                            child: Text(
                              _isCreateMode
                                  ? 'Already have an account? Sign in'
                                  : 'Need an account? Create one',
                              style: const TextStyle(color: Color(0xFF00BFFF), fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoginField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool obscure;
  final Widget? suffix;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;

  const _LoginField({
    required this.controller,
    required this.label,
    required this.icon,
    this.obscure = false,
    this.suffix,
    this.keyboardType,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      validator: validator,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.grey[500]),
        prefixIcon: Icon(icon, color: const Color(0xFF00BFFF), size: 20),
        suffixIcon: suffix,
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.04),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: const Color(0xFF00BFFF).withValues(alpha: 0.65)),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFFF5252)),
        ),
      ),
    );
  }
}
