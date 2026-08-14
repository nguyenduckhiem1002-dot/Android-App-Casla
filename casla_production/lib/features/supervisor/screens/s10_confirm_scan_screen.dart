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
      var worker = await db.getEmployeeByCode(code);

      if (worker == null) {
        // Fallback: search by partial match or ensure employee exists
        final all = await db.getAllEmployees();
        try {
          worker = all.firstWhere(
            (e) =>
                (e['ma_nv'] ?? '').toString().toLowerCase() ==
                    code.toLowerCase() ||
                (e['ten'] ?? '').toString().toLowerCase().contains(
                  code.toLowerCase(),
                ) ||
                (e['tai_khoan'] ?? '').toString().toLowerCase() ==
                    code.toLowerCase(),
          );
        } catch (_) {
          worker = await db.ensureEmployeeExists(
            code.toUpperCase(),
            'Công nhân $code',
          );
        }
      }

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
                  labelText: 'Mã số NV / Tài khoản (ví dụ: MNV00123)',
                  hintText: 'MNV00123 hoặc MNV00147',
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
              const Text(
                'Gợi ý quét nhanh cho quản lý:',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: CaslaColors.muted,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActionChip(
                    avatar: const Icon(Icons.person, size: 16),
                    label: const Text('MNV00123 (Nguyễn Văn A)'),
                    onPressed: () {
                      Navigator.pop(context);
                      _handleWorkerCodeScanned('MNV00123');
                    },
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.person, size: 16),
                    label: const Text('MNV00147 (Lê Thị C)'),
                    onPressed: () {
                      Navigator.pop(context);
                      _handleWorkerCodeScanned('MNV00147');
                    },
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.person, size: 16),
                    label: const Text('MNV00158 (Phạm Văn D)'),
                    onPressed: () {
                      Navigator.pop(context);
                      _handleWorkerCodeScanned('MNV00158');
                    },
                  ),
                ],
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
