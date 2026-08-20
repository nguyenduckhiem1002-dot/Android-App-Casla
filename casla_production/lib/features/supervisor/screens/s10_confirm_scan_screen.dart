// Screen S10 — Scan Worker QR & Confirm Production Screen
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../main.dart';
import '../../../presentation/widgets/qr_scanner_view.dart';

class S10ConfirmScanScreen extends ConsumerStatefulWidget {
  const S10ConfirmScanScreen({super.key});

  @override
  ConsumerState<S10ConfirmScanScreen> createState() =>
      _S10ConfirmScanScreenState();
}

class _S10ConfirmScanScreenState extends ConsumerState<S10ConfirmScanScreen> {
  bool _isProcessing = false;
  final TextEditingController _manualController = TextEditingController();

  @override
  void dispose() {
    _manualController.dispose();
    super.dispose();
  }

  Future<void> _handleWorkerCodeScanned(String rawCode) async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    try {
      String code = rawCode.trim();
      // If code is JSON payload, attempt parsing
      if (code.startsWith('{') && code.endsWith('}')) {
        try {
          final parsed = jsonDecode(code);
          if (parsed is Map && parsed.containsKey('ma_nv')) {
            code = parsed['ma_nv'].toString().trim();
          } else if (parsed is Map && parsed.containsKey('maNv')) {
            code = parsed['maNv'].toString().trim();
          }
        } catch (_) {}
      }

      final db = ref.read(appStateProvider).db;
      final worker = await db.getEmployeeByCode(code);
      if (worker == null) throw Exception('Unknown employee');
      final session = ref.read(appStateProvider).currentSession;
      final isInScope = await db.isEmployeeInScope(
        worker['id'] as String,
        session?.toIds ?? const [],
      );
      if (!isInScope) throw Exception('Employee outside supervisor scope');

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.white),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Đã khớp công nhân: ${worker['ten']} (${worker['ma_nv']})',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          backgroundColor: CaslaColors.success,
          duration: const Duration(seconds: 2),
        ),
      );

      // Redirect to Employee Daily Detail Screen (S06b)
      await context.push('/supervisor/employee_detail', extra: worker);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Không tìm thấy công nhân: $rawCode'),
            backgroundColor: CaslaColors.danger,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  void _showManualInputDialog() {
    _manualController.clear();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Nhập mã công nhân',
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                      color: CaslaColors.primaryNavy,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _manualController,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Mã số nhân viên / tài khoản',
                  hintText: 'Nhập chính xác mã nhân viên',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  prefixIcon: const Icon(Icons.badge_outlined),
                ),
                onSubmitted: (val) {
                  Navigator.pop(context);
                  _handleWorkerCodeScanned(val);
                },
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: CaslaColors.primaryNavy,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () {
                    final text = _manualController.text.trim();
                    if (text.isNotEmpty) {
                      Navigator.pop(context);
                      _handleWorkerCodeScanned(text);
                    }
                  },
                  child: const Text(
                    'Tìm & Mở phân công',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          QrScannerView(
            title: 'XÁC NHẬN CÔNG NHÂN',
            subtitle: 'Quét thẻ / mã QR công nhân để xem chi tiết & xác nhận',
            onScan: (code) => _handleWorkerCodeScanned(code),
            onManualInput: _showManualInputDialog,
          ),
          if (_isProcessing)
            Container(
              color: Colors.black54,
              alignment: Alignment.center,
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: CaslaColors.accentGold),
                  SizedBox(height: 16),
                  Text(
                    'Đang kiểm tra mã công nhân...',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
