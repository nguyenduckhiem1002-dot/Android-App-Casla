import 'package:flutter/material.dart';

import '../../app/theme/casla_colors.dart';
import '../../app/theme/casla_spacing.dart';
import '../../core/database/casla_database.dart';
import '../../core/scanner/scan_intent.dart';
import '../../core/utils/worker_qr_parser.dart';

/// Outcome of turning a scanned worker payload into a usable employee record.
sealed class WorkerScanOutcome {
  const WorkerScanOutcome();
}

class WorkerScanAccepted extends WorkerScanOutcome {
  final Map<String, dynamic> worker;

  const WorkerScanAccepted(this.worker);
}

class WorkerScanRejected extends WorkerScanOutcome {
  final String message;

  const WorkerScanRejected(this.message);
}

/// The operator cancelled the "this worker is not in the catalogue" prompt.
class WorkerScanCancelled extends WorkerScanOutcome {
  const WorkerScanCancelled();
}

/// Validates a scanned worker card and, when it is not already known to this
/// device, asks before creating it.
///
/// The app deliberately accepts workers that SAP has not sent down yet — that
/// is a product decision, and SAP still authorises the eventual write. But a
/// laser fires at whatever is in front of it, so an accidental sweep across a
/// carton label used to create a permanent employee row named after a product
/// barcode, silently. The confirmation costs one tap on the rare genuine new
/// card and stops every mis-scan from polluting the catalogue.
Future<WorkerScanOutcome> acceptScannedWorker(
  BuildContext context, {
  required String rawCode,
  required CaslaDatabase database,
  DateTime? now,
}) async {
  final parsed = WorkerQrParser.parse(rawCode);
  if (!parsed.isValid) {
    return WorkerScanRejected(parsed.error ?? 'Mã QR công nhân không hợp lệ.');
  }
  if (!parsed.isEffectiveOn(now ?? DateTime.now())) {
    return const WorkerScanRejected(
      'Thẻ công nhân này không còn hiệu lực trong ngày hôm nay.',
    );
  }

  final existing = await database.getEmployeeByCode(parsed.maNv);
  if (existing == null) {
    if (!context.mounted) return const WorkerScanCancelled();
    final confirmed = await _confirmUnknownWorker(
      context,
      parsed: parsed,
      rawCode: rawCode,
    );
    if (confirmed != true) return const WorkerScanCancelled();
  }

  final worker = await database.acceptWorkerQr(
    code: parsed.maNv,
    name: parsed.name,
    validFrom: parsed.validFrom,
    validTo: parsed.validTo,
  );
  return WorkerScanAccepted(worker);
}

Future<bool?> _confirmUnknownWorker(
  BuildContext context, {
  required WorkerQrResult parsed,
  required String rawCode,
}) {
  final looksLikeProduct = ScanClassifier.looksLikeRetailBarcode(parsed.maNv);

  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      icon: Icon(
        looksLikeProduct
            ? Icons.warning_amber_rounded
            : Icons.person_add_alt_1_outlined,
        color: looksLikeProduct ? CaslaColors.danger : CaslaColors.accentGold,
        size: 32,
      ),
      title: Text(
        looksLikeProduct ? 'Có thể quét nhầm mã hàng' : 'Công nhân chưa có',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            looksLikeProduct
                ? 'Mã vừa quét trông giống mã vạch trên thùng hàng, không giống thẻ nhân viên.'
                : 'Mã này chưa có trong danh mục trên máy.',
            style: const TextStyle(fontSize: CaslaType.body, height: 1.4),
          ),
          const SizedBox(height: CaslaSpacing.sm),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(CaslaSpacing.sm),
            decoration: BoxDecoration(
              color: CaslaColors.muted100,
              borderRadius: BorderRadius.circular(CaslaRadius.sm),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DialogField(label: 'Mã đã quét', value: parsed.maNv),
                if (parsed.name.isNotEmpty)
                  _DialogField(label: 'Tên trên thẻ', value: parsed.name),
              ],
            ),
          ),
          const SizedBox(height: CaslaSpacing.sm),
          Text(
            looksLikeProduct
                ? 'Nếu tiếp tục, app sẽ tạo một công nhân mới mang đúng mã này.'
                : 'Tiếp tục sẽ tạo công nhân mới trên máy để giao việc. Quyền và tổ vẫn do SAP quyết định.',
            style: const TextStyle(
              fontSize: CaslaType.caption,
              color: CaslaColors.muted,
              height: 1.4,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Quét lại'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          style: looksLikeProduct
              ? FilledButton.styleFrom(backgroundColor: CaslaColors.danger)
              : null,
          child: const Text('Vẫn thêm'),
        ),
      ],
    ),
  );
}

class _DialogField extends StatelessWidget {
  final String label;
  final String value;

  const _DialogField({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: CaslaType.caption,
                color: CaslaColors.muted,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: CaslaType.body,
                fontWeight: FontWeight.w700,
                color: CaslaColors.primaryNavy,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
