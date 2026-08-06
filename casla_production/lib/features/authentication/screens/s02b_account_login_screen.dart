import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../main.dart';

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
  final TextEditingController _passwordController =
      TextEditingController(text: '123456');
  bool _obscurePassword = true;
  String? _errorMessage;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _usernameController =
        TextEditingController(text: widget.initialUsername ?? 'tranthib');
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

    final db = ref.read(appStateProvider).db;
    final emp = await db.login(username, password);

    if (!mounted) return;

    setState(() {
      _isLoading = false;
    });

    if (emp == null) {
      setState(() {
        _errorMessage = 'Sai tài khoản hoặc mật khẩu';
      });
      return;
    }

    await ref.read(appStateProvider).loginByMaNv(emp['ma_nv']);

    if (!mounted) return;
    if (emp['vai_tro'] == 'SUPERVISOR') {
      context.go('/supervisor');
    } else {
      context.go('/worker');
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
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [CaslaColors.accentGold, CaslaColors.gold700],
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: const Text(
                    'CG',
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontWeight: FontWeight.w800,
                      fontSize: 22,
                      color: CaslaColors.navy900,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Đăng nhập tài khoản',
                  style: TextStyle(
                    fontFamily: 'Manrope',
                    fontWeight: FontWeight.w800,
                    fontSize: 20,
                    color: CaslaColors.primaryNavy,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Đăng nhập dành cho Supervisor & Công nhân',
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

                const SizedBox(height: 24),
                const Divider(height: 1),
                const SizedBox(height: 16),

                // Quick Demo User Selector Chips
                const Text(
                  '⚡ Đăng nhập nhanh 5 Tài khoản Demo:',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: CaslaColors.muted,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    _buildDemoChip('Supervisor (Trần Thị B)', 'tranthib'),
                    _buildDemoChip('1. SYNCED (Nguyễn Văn A)', 'vana123'),
                    _buildDemoChip('2. PENDING (Lê Thị C)', 'lethic'),
                    _buildDemoChip('3. FAILED (Phạm Văn D)', 'phamvand'),
                    _buildDemoChip('4. CHƯA XÁC NHẬN (Hoàng Văn E)', 'hoangvane'),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDemoChip(String label, String username) {
    return ActionChip(
      backgroundColor: CaslaColors.gold100,
      side: const BorderSide(color: CaslaColors.gold700, width: 1),
      label: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: CaslaColors.gold700,
        ),
      ),
      onPressed: () {
        _usernameController.text = username;
        _passwordController.text = '123456';
        _submitLogin(username, '123456');
      },
    );
  }
}
