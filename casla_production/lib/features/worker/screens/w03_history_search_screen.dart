// W03 — Tìm kiếm (tài khoản xem lịch sử team, PP_HIST_TEAM)
//
// One place to look a history up: pull the PDA trigger or use the camera on
// a worker's card or an operation label, or type a worker code, or a
// production order and operation. Each opens W01 on that worker or that
// operation over the chosen period.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/casla_colors.dart';
import '../../../domain/entities/work_history.dart';
import '../../../main.dart';
import '../../../presentation/widgets/barcode_scan_listener.dart';
import '../../../presentation/widgets/worker_search_field.dart';

/// SAP's operation number is four digits: "10" is "0010".
String normalizeOperationNumber(String value) {
  final digits = value.trim();
  if (digits.isEmpty || digits.length > 4) return digits;
  return digits.padLeft(4, '0');
}

class W03HistorySearchScreen extends ConsumerStatefulWidget {
  const W03HistorySearchScreen({super.key});

  @override
  ConsumerState<W03HistorySearchScreen> createState() =>
      _W03HistorySearchScreenState();
}

class _W03HistorySearchScreenState
    extends ConsumerState<W03HistorySearchScreen> {
  HistoryRange _range = HistoryRange.day;
  final _workerController = TextEditingController();
  final _orderController = TextEditingController();
  final _operationController = TextEditingController();
  String? _workerError;
  String? _operationError;

  @override
  void dispose() {
    _workerController.dispose();
    _orderController.dispose();
    _operationController.dispose();
    super.dispose();
  }

  bool _onScanned(String raw) {
    final scan = classifyHistoryScan(raw);
    switch (scan) {
      case OperationHistoryScan():
        _orderController.text = scan.productionOrder;
        _operationController.text = scan.operation;
        openOperationHistory(context, scan, range: _range);
        return true;
      case WorkerHistoryScan(:final code):
        _workerController.text = code;
        openWorkerHistory(context, code: code, range: _range);
        return true;
      case null:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mã QR không phải thẻ công nhân hay QR công đoạn.'),
          ),
        );
        return false;
    }
  }

  Future<void> _scanWithCamera() async {
    final raw = await scanHistoryCodeWithCamera(context);
    if (raw != null && mounted) _onScanned(raw);
  }

  void _searchWorker() {
    final code = _workerController.text.trim().toUpperCase();
    if (code.isEmpty) {
      setState(() => _workerError = 'Nhập mã nhân viên.');
      return;
    }
    setState(() => _workerError = null);
    openWorkerHistory(context, code: code, range: _range);
  }

  void _searchOperation() {
    final order = _orderController.text.trim();
    final operation = normalizeOperationNumber(_operationController.text);
    if (order.isEmpty || operation.isEmpty) {
      setState(() => _operationError = 'Nhập cả lệnh sản xuất và công đoạn.');
      return;
    }
    if (order.length > 12 || operation.length > 4) {
      setState(
        () => _operationError =
            'Lệnh sản xuất tối đa 12 số, công đoạn tối đa 4 số.',
      );
      return;
    }
    setState(() => _operationError = null);
    _operationController.text = operation;
    openOperationHistory(
      context,
      OperationHistoryScan(productionOrder: order, operation: operation),
      range: _range,
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(appStateProvider).currentSession;
    return Scaffold(
      backgroundColor: CaslaColors.background,
      appBar: AppBar(
        backgroundColor: CaslaColors.primaryNavy,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Tìm kiếm',
              style: TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w800,
                fontSize: 19,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              session?.fullName ?? '',
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: CaslaColors.identityMeta,
              ),
            ),
          ],
        ),
      ),
      body: BarcodeScanListener(
        // The PDA trigger works anywhere on this tab.
        onScan: _onScanned,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 32),
          children: [
            _buildRangeTabs(),
            const SizedBox(height: 14),
            _buildScanCard(),
            const SizedBox(height: 18),
            _sectionTitle('Theo công nhân'),
            const SizedBox(height: 8),
            TextField(
              key: const Key('search-worker-code'),
              controller: _workerController,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _searchWorker(),
              decoration: _decoration(
                'Mã nhân viên, ví dụ CL400082',
                icon: Icons.badge_outlined,
                error: _workerError,
              ),
            ),
            const SizedBox(height: 8),
            _searchButton(
              key: const Key('search-worker-go'),
              onPressed: _searchWorker,
            ),
            const SizedBox(height: 22),
            _sectionTitle('Theo công đoạn'),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    key: const Key('search-production-order'),
                    controller: _orderController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textInputAction: TextInputAction.next,
                    decoration: _decoration(
                      'Lệnh sản xuất',
                      icon: Icons.receipt_long_outlined,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    key: const Key('search-operation'),
                    controller: _operationController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _searchOperation(),
                    decoration: _decoration('Công đoạn'),
                  ),
                ),
              ],
            ),
            if (_operationError != null) ...[
              const SizedBox(height: 6),
              Text(
                _operationError!,
                style: const TextStyle(color: CaslaColors.danger, fontSize: 12),
              ),
            ],
            const SizedBox(height: 8),
            _searchButton(
              key: const Key('search-operation-go'),
              onPressed: _searchOperation,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRangeTabs() {
    Widget tab(String label, HistoryRange range) {
      final selected = range == _range;
      return Expanded(
        child: InkWell(
          onTap: () => setState(() => _range = range),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? CaslaColors.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? CaslaColors.primaryNavy : CaslaColors.muted,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: CaslaColors.muted100,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          tab('Hôm nay', HistoryRange.day),
          tab('Tuần này', HistoryRange.week),
          tab('Tháng này', HistoryRange.month),
        ],
      ),
    );
  }

  Widget _buildScanCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: CaslaColors.surface,
        border: Border.all(color: CaslaColors.line),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.qr_code_scanner,
            size: 44,
            color: CaslaColors.primaryNavy,
          ),
          const SizedBox(height: 8),
          const Text(
            'Quét thẻ công nhân hoặc QR công đoạn',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Manrope',
              fontWeight: FontWeight.w800,
              fontSize: 15,
              color: CaslaColors.primaryNavy,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Bóp cò đầu đọc, hoặc bấm nút bên dưới để quét bằng camera.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: CaslaColors.muted),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton.icon(
              key: const Key('search-scan-camera'),
              style: FilledButton.styleFrom(
                backgroundColor: CaslaColors.primaryNavy,
              ),
              onPressed: _scanWithCamera,
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('Quét bằng camera'),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _sectionTitle(String text) => Text(
    text,
    style: const TextStyle(
      fontFamily: 'Manrope',
      fontWeight: FontWeight.w800,
      fontSize: 14,
      color: CaslaColors.primaryNavy,
    ),
  );

  static InputDecoration _decoration(
    String hint, {
    IconData? icon,
    String? error,
  }) => InputDecoration(
    isDense: true,
    hintText: hint,
    errorText: error,
    prefixIcon: icon == null ? null : Icon(icon, size: 20),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
  );

  static Widget _searchButton({
    required Key key,
    required VoidCallback onPressed,
  }) => SizedBox(
    width: double.infinity,
    height: 44,
    child: OutlinedButton.icon(
      key: key,
      onPressed: onPressed,
      icon: const Icon(Icons.history, size: 18),
      label: const Text('Xem lịch sử'),
      style: OutlinedButton.styleFrom(
        foregroundColor: CaslaColors.primaryNavy,
        side: const BorderSide(color: CaslaColors.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}
