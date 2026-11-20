// Finding a worker on the history and team overview screens: type a code,
// a name or a department code, or scan the worker's card — with the
// camera button here, or with the PDA trigger through a BarcodeScanListener
// the screen wraps around itself (see [workerCodeFromScan]).

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/utils/operation_qr_parser.dart';
import '../../core/utils/worker_qr_parser.dart';
import '../../domain/entities/work_history.dart';
import '../../domain/policies/worker_position_policy.dart';
import 'adaptive_barcode_scanner_view.dart';

/// The worker code a scan names: the employee code of a worker QR, or a
/// bare code read off a printed label. Null when the payload is neither.
String? workerCodeFromScan(String raw) {
  final parsed = WorkerQrParser.parse(raw);
  if (parsed.isValid && parsed.maNv.trim().isNotEmpty) {
    return parsed.maNv.trim().toUpperCase();
  }
  final bare = raw.trim();
  if (bare.isEmpty || bare.length > 20) return null;
  if (!RegExp(r'^[A-Za-z0-9_\-.]+$').hasMatch(bare)) return null;
  return bare.toUpperCase();
}

/// What a scan on a history screen points at.
sealed class HistoryScan {
  const HistoryScan();
}

/// A worker's card.
class WorkerHistoryScan extends HistoryScan {
  final String code;

  const WorkerHistoryScan(this.code);
}

/// An operation label: production order and operation.
class OperationHistoryScan extends HistoryScan {
  final String productionOrder;
  final String operation;
  final String operationName;

  const OperationHistoryScan({
    required this.productionOrder,
    required this.operation,
    this.operationName = '',
  });
}

/// Opens one worker's history (W01 on that worker), over [range].
Future<void> openWorkerHistory(
  BuildContext context, {
  required String code,
  String name = '',
  HistoryRange? range,
}) => context.push(
  '/history/worker',
  extra: <String, dynamic>{'code': code, 'name': name, 'range': range},
);

/// Opens one operation's history, every worker who took it, over [range].
Future<void> openOperationHistory(
  BuildContext context,
  OperationHistoryScan scan, {
  HistoryRange? range,
}) => context.push(
  '/history/operation',
  extra: <String, dynamic>{
    'production_order': scan.productionOrder,
    'operation': scan.operation,
    'operation_name': scan.operationName,
    'range': range,
  },
);

/// Reads [raw] as an operation label first (it names both a production
/// order and an operation, which no worker card does), else as a worker
/// card. Null when it is neither.
HistoryScan? classifyHistoryScan(String raw) {
  final operation = OperationQrParser.parse(raw);
  if (operation.isValid &&
      operation.productionOrder.trim().isNotEmpty &&
      operation.operation.trim().isNotEmpty) {
    return OperationHistoryScan(
      productionOrder: operation.productionOrder.trim(),
      operation: operation.operation.trim(),
      operationName: operation.operationName.trim(),
    );
  }
  final code = workerCodeFromScan(raw);
  return code == null ? null : WorkerHistoryScan(code);
}

/// A label that names a position (keyed `VT=A-01`, JSON, `A-01@A1`). Bare
/// codes are not: they read as worker codes until a board says otherwise.
bool isPositionLabelScan(String raw) =>
    (parsePositionLabel(raw)?.positionId ?? '').isNotEmpty;

/// Opens the camera scanner and returns the raw payload of a worker card
/// or an operation label (with [acceptPositions], a position label too), or
/// null when the operator backed out.
Future<String?> scanHistoryCodeWithCamera(
  BuildContext context, {
  bool acceptPositions = false,
}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (routeContext) => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            AdaptiveBarcodeScannerView(
              title: 'Quét QR',
              subtitle: acceptPositions
                  ? 'Đưa thẻ công nhân, QR vị trí hoặc QR công đoạn vào '
                        'khung hình.'
                  : 'Đưa thẻ công nhân hoặc QR công đoạn vào khung hình.',
              onScan: (code) {
                final known =
                    classifyHistoryScan(code) != null ||
                    (acceptPositions && isPositionLabelScan(code));
                if (!known) return false;
                Navigator.of(routeContext).pop(code);
                return true;
              },
            ),
            Positioned(
              top: MediaQuery.paddingOf(routeContext).top + 8,
              left: 10,
              child: Material(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(24),
                child: IconButton(
                  tooltip: 'Đóng quét QR',
                  onPressed: () => Navigator.of(routeContext).pop(),
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Search box with a clear button and a QR button.
class WorkerSearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  /// Called with the raw payload the camera read: a worker card or an
  /// operation label (see [classifyHistoryScan]).
  final ValueChanged<String> onScanned;
  final String hintText;

  const WorkerSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onScanned,
    this.hintText = 'Tìm theo mã NV, tên hoặc mã tổ',
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => TextField(
        key: const Key('history-worker-search'),
        controller: controller,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 20),
          hintText: hintText,
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (value.text.isNotEmpty)
                IconButton(
                  tooltip: 'Xóa tìm kiếm',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
              IconButton(
                key: const Key('history-worker-scan'),
                tooltip: 'Quét thẻ công nhân hoặc QR công đoạn',
                icon: const Icon(Icons.qr_code_scanner, size: 20),
                onPressed: () async {
                  final code = await scanHistoryCodeWithCamera(context);
                  if (code != null) onScanned(code);
                },
              ),
            ],
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onChanged: onChanged,
      ),
    );
  }
}
