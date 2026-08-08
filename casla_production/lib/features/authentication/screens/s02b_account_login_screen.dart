import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../presentation/widgets/casla_logo_white.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../main.dart';
import '../../account/widgets/change_password_dialog.dart';

class S02bAccountLoginScreen extends ConsumerStatefulWidget {
  final String? initialUsername;

  const S02bAccountLoginScreen({
    super.key,
    this.initialUsername,
  });

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
    _usernameController =
        TextEditingController(text: widget.initialUsername ?? '');
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
      await ref.read(appStateProvider).loginByCredentials(username, password);
      if (!mounted) return;
      context.go('/supervisor');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
      });
    } finally {
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
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Logo
                const CaslaLogo(
                  height: 68,
                  isDarkBackground: false,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Đăng nhập Supervisor',
                  style: TextStyle(
                    fontFamily: 'Manrope',
                    fontWeight: FontWeight.w800,
                    fontSize: 20,
                    color: CaslaColors.primaryNavy,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Dành riêng cho Supervisor quản lý sản xuất',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: CaslaColors.muted,
                  ),
                ),
                const SizedBox(height: 24),

                // Username field
                Align(
                  alignment: Alignment.centerLeft,
                  child: RichText(
                    text: const TextSpan(
                      text: 'Tài khoản ',
                      style: TextStyle(
                        fontSize: 12,
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
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    suffixIcon: Icon(Icons.person_outline, size: 20),
                  ),
                ),
                const SizedBox(height: 16),

                // Password field
                Align(
                  alignment: Alignment.centerLeft,
                  child: RichText(
                    text: const TextSpan(
                      text: 'Mật khẩu ',
                      style: TextStyle(
                        fontSize: 12,
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
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        size: 20,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscurePassword = !_obscurePassword;
                        });
                      },
                    ),
                  ),
                ),

                if (_errorMessage != null) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(
                        color: CaslaColors.danger,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 20),

                // Login Button
                ElevatedButton(
                  onPressed: _isLoading ? null : () => _submitLogin(),
                  child: _isLoading
                      ? const SizedBox(
                          width: 24,
                          height: 24,
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
      ),
    );
  }
}
