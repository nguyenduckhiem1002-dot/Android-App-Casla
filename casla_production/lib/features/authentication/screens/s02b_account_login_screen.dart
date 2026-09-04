import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../presentation/widgets/casla_logo.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../domain/entities/enums.dart';
import '../../../main.dart';

class S02bAccountLoginScreen extends ConsumerStatefulWidget {
  final String? initialUsername;

  const S02bAccountLoginScreen({super.key, this.initialUsername});

  @override
  ConsumerState<S02bAccountLoginScreen> createState() =>
      _S02bAccountLoginScreenState();
}

class _S02bAccountLoginScreenState
    extends ConsumerState<S02bAccountLoginScreen> {
  late TextEditingController _usernameController;
  final TextEditingController _passwordController = TextEditingController();
  bool _obscurePassword = true;
  String? _errorMessage;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _usernameController = TextEditingController(
      text: widget.initialUsername ?? '',
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submitLogin([String? customUser, String? customPass]) async {
    final username = customUser ?? _usernameController.text.trim();
    final password = customPass ?? _passwordController.text;

    if (username.isEmpty || password.isEmpty) {
      setState(() {
        _errorMessage = 'Vui lòng nhập đầy đủ tài khoản và mật khẩu';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final appState = ref.read(appStateProvider);
      await appState.loginByCredentials(username, password);
      if (!mounted) return;
      final role = appState.currentSession?.role;
      _passwordController.clear();
      context.go(role == UserRole.worker ? '/history' : '/supervisor');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
      });
    } finally {
      // Do not retain credentials in the controller after an authentication
      // attempt (successful or otherwise).
      _passwordController.clear();
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CaslaColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Logo & Header Branding
                  const CaslaLogo(height: 72, isDarkBackground: false),
                  const SizedBox(height: 16),
                  const Text(
                    'Đăng nhập',
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontWeight: FontWeight.w800,
                      fontSize: 22,
                      letterSpacing: -0.3,
                      color: CaslaColors.primaryNavy,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Hệ thống ghi nhận sản lượng Casla Group',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: CaslaColors.muted,
                    ),
                  ),
                  const SizedBox(height: 28),

                  // Login Form Card
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Error Banner
                          if (_errorMessage != null) ...[
                            Semantics(
                              liveRegion: true,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  color: CaslaColors.dangerBg,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: CaslaColors.danger.withValues(
                                      alpha: 0.25,
                                    ),
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Icon(
                                      Icons.error_outline_rounded,
                                      color: CaslaColors.danger,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        _errorMessage!,
                                        style: const TextStyle(
                                          color: CaslaColors.danger,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          height: 1.3,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 18),
                          ],

                          // Username field
                          RichText(
                            text: const TextSpan(
                              text: 'Tài khoản ',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: CaslaColors.primaryNavy,
                              ),
                              children: [
                                TextSpan(
                                  text: '*',
                                  style: TextStyle(color: CaslaColors.danger),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _usernameController,
                            autofillHints: const [AutofillHints.username],
                            autocorrect: false,
                            enableSuggestions: false,
                            textInputAction: TextInputAction.next,
                            onChanged: (_) {
                              if (_errorMessage != null) {
                                setState(() => _errorMessage = null);
                              }
                            },
                            decoration: const InputDecoration(
                              hintText: 'Nhập mã quản lý / username',
                              prefixIcon: Icon(
                                Icons.person_outline_rounded,
                                size: 20,
                                color: CaslaColors.muted,
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),

                          // Password field
                          RichText(
                            text: const TextSpan(
                              text: 'Mật khẩu ',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: CaslaColors.primaryNavy,
                              ),
                              children: [
                                TextSpan(
                                  text: '*',
                                  style: TextStyle(color: CaslaColors.danger),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _passwordController,
                            autofillHints: const [AutofillHints.password],
                            autocorrect: false,
                            enableSuggestions: false,
                            obscureText: _obscurePassword,
                            textInputAction: TextInputAction.done,
                            onChanged: (_) {
                              if (_errorMessage != null) {
                                setState(() => _errorMessage = null);
                              }
                            },
                            onSubmitted: (_) {
                              if (!_isLoading) _submitLogin();
                            },
                            decoration: InputDecoration(
                              hintText: 'Nhập mật khẩu',
                              prefixIcon: const Icon(
                                Icons.lock_outline_rounded,
                                size: 20,
                                color: CaslaColors.muted,
                              ),
                              suffixIcon: IconButton(
                                tooltip: _obscurePassword
                                    ? 'Hiện mật khẩu'
                                    : 'Ẩn mật khẩu',
                                icon: Icon(
                                  _obscurePassword
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                  size: 20,
                                  color: CaslaColors.muted,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _obscurePassword = !_obscurePassword;
                                  });
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),

                          // Login Button
                          ElevatedButton(
                            onPressed: _isLoading ? null : () => _submitLogin(),
                            child: _isLoading
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: CaslaColors.navy900,
                                    ),
                                  )
                                : const Text('Đăng nhập'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
