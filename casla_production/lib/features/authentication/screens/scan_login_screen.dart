// Screen S02 — QR Scan Login
// Spec: Section 5.2 S02 (Camera viewfinder + manual entry)

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../app/theme/casla_typography.dart';

class ScanLoginScreen extends StatefulWidget {
  final Future<void> Function(String username, String? password) onLoginSuccess;

  const ScanLoginScreen({super.key, required this.onLoginSuccess});

  @override
  State<ScanLoginScreen> createState() => _ScanLoginScreenState();
}

class _ScanLoginScreenState extends State<ScanLoginScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _scanLineController;
  final _manualController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _showManualInput = true; // Default to manual login (light theme)
  bool _isLoading = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _scanLineController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _scanLineController.dispose();
    _manualController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_showManualInput) {
      return _buildManualLogin(context);
    } else {
      return _buildScannerLogin(context);
    }
  }

  Widget _buildManualLogin(BuildContext context) {
    return Scaffold(
      backgroundColor: CaslaColors.background, // Light background
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 80),
              // Logo
              Center(
                child: Container(
                  width: 56, height: 56,
                  decoration: BoxDecoration(
                    color: CaslaColors.accentGold,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  alignment: Alignment.center,
                  child: const Text('CG', style: TextStyle(
                    fontFamily: CaslaTypography.fontDisplay,
                    fontWeight: FontWeight.w800, fontSize: 22,
                    color: CaslaColors.navy900,
                  )),
                ),
              ),
              const SizedBox(height: 24),
              // Title
              const Text('Đăng nhập tài khoản', 
                textAlign: TextAlign.center,
                style: CaslaTypography.screenTitle,
              ),
              const SizedBox(height: 8),
              const Text('Dùng cho cả Supervisor và Công nhân — quyền hạn được\ncấp theo tài khoản SAP.', 
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: CaslaColors.muted, height: 1.4),
              ),
              
              const SizedBox(height: 48),

              // Username Field
              RichText(
                text: const TextSpan(
                  text: 'Tài khoản ', style: CaslaTypography.label,
                  children: [
                    TextSpan(text: '*', style: TextStyle(color: CaslaColors.danger)),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _manualController,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.white,
                  suffixIcon: const Icon(Icons.person_outline, color: CaslaColors.primaryNavy),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: CaslaColors.line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: CaslaColors.accentGold, width: 2),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Password Field
              RichText(
                text: const TextSpan(
                  text: 'Mật khẩu ', style: CaslaTypography.label,
                  children: [
                    TextSpan(text: '*', style: TextStyle(color: CaslaColors.danger)),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.white,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                      color: CaslaColors.primaryNavy,
                    ),
                    onPressed: () {
                      setState(() {
                        _obscurePassword = !_obscurePassword;
                      });
                    },
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: CaslaColors.line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: CaslaColors.accentGold, width: 2),
                  ),
                ),
                onSubmitted: (_) => _handleLogin(),
              ),
              const SizedBox(height: 16),

              // Forgot password link
              Align(
                alignment: Alignment.centerRight,
                child: Text('Quên mật khẩu?', style: TextStyle(
                  fontSize: 13, 
                  color: CaslaColors.muted,
                  decoration: TextDecoration.underline,
                  fontWeight: FontWeight.w600,
                )),
              ),

              const SizedBox(height: 32),

              // Login Button
              SizedBox(
                height: 52,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _handleLogin,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: CaslaColors.accentGold,
                    foregroundColor: CaslaColors.navy900,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    elevation: 0,
                  ),
                  child: _isLoading 
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: CaslaColors.navy900, strokeWidth: 2))
                    : const Text('Đăng nhập', style: CaslaTypography.button),
                ),
              ),

              const SizedBox(height: 48),

              // Switch to Scanner Link
              Center(
                child: GestureDetector(
                  onTap: () => setState(() => _showManualInput = false),
                  child: const Text('Dùng mã badge để quét thay thế', style: TextStyle(
                    fontSize: 14,
                    color: CaslaColors.pending, // Gold/brownish
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.underline,
                  )),
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScannerLogin(BuildContext context) {
    return Scaffold(
      backgroundColor: CaslaColors.navy900,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 50),
            // Logo & branding
            const _CaslaLogo(),
            const SizedBox(height: 14),
            const Text('Casla Group', style: TextStyle(
              fontFamily: CaslaTypography.fontDisplay,
              fontWeight: FontWeight.w800,
              fontSize: 22,
              color: Colors.white,
            )),
            const SizedBox(height: 4),
            const Text('Ghi nhận sản lượng', style: TextStyle(
              fontSize: 13,
              color: CaslaColors.accentLabelDark,
              fontWeight: FontWeight.w500,
            )),

            const SizedBox(height: 40),

            // Scan area
            Expanded(
              child: Center(
                child: _ScannerViewfinder(
                  animation: _scanLineController,
                  onDetect: (code) {
                    if (!_isLoading) {
                      _manualController.text = code;
                      _passwordController.text = ''; // or default password if any
                      _handleLogin();
                    }
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ElevatedButton.icon(
                onPressed: () {
                  // Simulate scan for Emulator
                  _manualController.text = 'MNV00123';
                  _passwordController.text = '123456';
                  _handleLogin();
                },
                icon: const Icon(Icons.bug_report),
                label: const Text('Mô phỏng Quét (Emulator)'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: CaslaColors.primaryNavy,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Quét mã nhân viên để đăng nhập',
                style: TextStyle(
                  fontSize: 13, color: Colors.white.withOpacity(0.6),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),

            // Toggle button
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: TextButton.icon(
                  onPressed: () {
                    setState(() => _showManualInput = true);
                  },
                  icon: const Icon(
                    Icons.keyboard,
                    size: 16, color: CaslaColors.accentGold,
                  ),
                  label: const Text(
                    'Nhập mã thủ công',
                    style: TextStyle(
                      color: CaslaColors.accentGold, fontSize: 13, fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),

            // Demo accounts
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                ),
              ),
              child: Column(
                children: [
                  Text('TÀI KHOẢN DEMO', style: TextStyle(
                    fontFamily: 'monospace', fontSize: 10, letterSpacing: 1.2,
                    color: Colors.white.withOpacity(0.35), fontWeight: FontWeight.w700,
                  )),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _DemoChip(
                        label: 'MNV00123',
                        sub: 'Công nhân',
                        onTap: () => widget.onLoginSuccess('MNV00123', null),
                      ),
                      const SizedBox(width: 8),
                      _DemoChip(
                        label: 'MNV00100',
                        sub: 'Supervisor',
                        onTap: () => widget.onLoginSuccess('MNV00100', null),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleLogin() async {
    final code = _manualController.text.trim();
    final pwd = _passwordController.text.trim();
    if (code.isEmpty || pwd.isEmpty) return;

    setState(() => _isLoading = true);
    try {
      await widget.onLoginSuccess(code, pwd);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString().replaceAll('Exception: ', '')),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
}

// ─── Logo ───────────────────────────────────────────────────────────
class _CaslaLogo extends StatelessWidget {
  const _CaslaLogo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 70, height: 70,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [CaslaColors.accentGold, CaslaColors.gold700],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: CaslaColors.accentGold.withOpacity(0.3),
            blurRadius: 20, offset: const Offset(0, 8),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: const Text('CG', style: TextStyle(
        fontFamily: CaslaTypography.fontDisplay,
        fontWeight: FontWeight.w800, fontSize: 28,
        color: CaslaColors.navy900,
      )),
    );
  }
}

// ─── Scanner Viewfinder ─────────────────────────────────────────────
class _ScannerViewfinder extends StatefulWidget {
  final AnimationController animation;
  final ValueChanged<String> onDetect;

  const _ScannerViewfinder({required this.animation, required this.onDetect});

  @override
  State<_ScannerViewfinder> createState() => _ScannerViewfinderState();
}

class _ScannerViewfinderState extends State<_ScannerViewfinder> {
  final MobileScannerController _cameraController = MobileScannerController();

  @override
  void dispose() {
    _cameraController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220, height: 220,
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: MobileScanner(
              controller: _cameraController,
              onDetect: (capture) {
                final List<Barcode> barcodes = capture.barcodes;
                if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
                  widget.onDetect(barcodes.first.rawValue!);
                }
              },
            ),
          ),
          // Corner brackets (matching index.html gold corners)
          CustomPaint(
            size: const Size(220, 220),
            painter: _ViewfinderPainter(),
          ),
          // Scan line animation
          AnimatedBuilder(
            animation: widget.animation,
            builder: (context, child) {
              return Positioned(
                top: widget.animation.value * 196 + 12,
                left: 12, right: 12,
                child: Container(
                  height: 2,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        CaslaColors.accentGold.withOpacity(0.0),
                        CaslaColors.accentGold,
                        CaslaColors.accentGold.withOpacity(0.0),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ViewfinderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = CaslaColors.accentGold
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const cornerLen = 34.0;
    final w = size.width;
    final h = size.height;

    // Top-Left
    canvas.drawLine(const Offset(0, 0), const Offset(cornerLen, 0), paint);
    canvas.drawLine(const Offset(0, 0), const Offset(0, cornerLen), paint);

    // Top-Right
    canvas.drawLine(Offset(w, 0), Offset(w - cornerLen, 0), paint);
    canvas.drawLine(Offset(w, 0), Offset(w, cornerLen), paint);

    // Bottom-Left
    canvas.drawLine(Offset(0, h), Offset(cornerLen, h), paint);
    canvas.drawLine(Offset(0, h), Offset(0, h - cornerLen), paint);

    // Bottom-Right
    canvas.drawLine(Offset(w, h), Offset(w - cornerLen, h), paint);
    canvas.drawLine(Offset(w, h), Offset(w, h - cornerLen), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ─── Demo Chip ──────────────────────────────────────────────────────
class _DemoChip extends StatelessWidget {
  final String label;
  final String sub;
  final VoidCallback onTap;

  const _DemoChip({required this.label, required this.sub, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white.withOpacity(0.15)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(
                fontFamily: 'monospace', fontWeight: FontWeight.w700,
                fontSize: 12, color: CaslaColors.accentGold,
              )),
              Text(sub, style: TextStyle(
                fontSize: 10, color: Colors.white.withOpacity(0.4),
              )),
            ],
          ),
        ),
      ),
    );
  }
}
