import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../main.dart';
import '../../../presentation/widgets/qr_scanner_view.dart';

import '../../../core/utils/worker_qr_parser.dart';

class S02ScanLoginScreen extends ConsumerWidget {
  const S02ScanLoginScreen({super.key});

  void _handleScan(BuildContext context, WidgetRef ref, String rawCode) async {
    final res = WorkerQrParser.parse(rawCode);
    if (!res.isValid) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res.error ?? 'Mã QR không hợp lệ'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final maNv = res.maNv;
    final db = ref.read(appStateProvider).db;
    final emp = await db.getEmployeeByCode(maNv);

    if (!context.mounted) return;

    if (emp == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Không tìm thấy mã nhân viên: ${res.displayText}'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final role = emp['vai_tro'];
    if (role == 'CONG_NHAN') {
      // Direct login for worker
      await ref.read(appStateProvider).loginByMaNv(maNv);
      if (context.mounted) {
        context.go('/worker');
      }
    } else if (role == 'SUPERVISOR') {
      // Navigate to account login with prefilled username
      context.push('/login/account', extra: emp['tai_khoan']);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E1730),
      body: QrScannerView(
        title: 'Quét mã nhân viên',
        subtitle:
            'Đưa mã badge vào khung hình hoặc dùng đầu đọc PDA để bắt đầu phiên làm việc.',
        onManualInput: () {
          context.push('/login/account');
        },
        onScan: (code) => _handleScan(context, ref, code),
      ),
    );
  }
}
