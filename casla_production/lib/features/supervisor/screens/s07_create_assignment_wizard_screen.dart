import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../main.dart';
import '../../../presentation/widgets/qr_scanner_view.dart';

import '../../../core/utils/worker_qr_parser.dart';

class S07CreateAssignmentWizardScreen extends ConsumerStatefulWidget {
  const S07CreateAssignmentWizardScreen({super.key});

  @override
  ConsumerState<S07CreateAssignmentWizardScreen> createState() =>
      _S07CreateAssignmentWizardScreenState();
}

class _S07CreateAssignmentWizardScreenState
    extends ConsumerState<S07CreateAssignmentWizardScreen> {
  Map<String, dynamic>? _selectedWorker;
  Map<String, dynamic>? _selectedOrder;
  final TextEditingController _qtyController = TextEditingController(
    text: '200',
  );
  final TextEditingController _noteController = TextEditingController();
  DateTime _startDate = DateTime.now();
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _qtyController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _openWorkerPicker() {
    _scanWorkerQR();
  }

  void _scanWorkerQR() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          body: QrScannerView(
            title: 'Quét mã QR công nhân',
            subtitle: 'Đưa thẻ nhân viên vào khung hình.',
            onScan: (code) async {
              final res = WorkerQrParser.parse(code);
              if (!res.isValid) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(res.error ?? 'Mã QR không hợp lệ'),
                    backgroundColor: CaslaColors.danger,
                  ),
                );
                return;
              }
              final worker = await ref
                  .read(appStateProvider)
                  .db
                  .getEmployeeByCode(res.maNv);
              if (!mounted || !context.mounted) return;
              if (worker == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Nhân viên chưa tồn tại trong dữ liệu được phân quyền.',
                    ),
                    backgroundColor: CaslaColors.danger,
                  ),
                );
                return;
              }
              final session = ref.read(appStateProvider).currentSession;
              final isInScope = await ref
                  .read(appStateProvider)
                  .db
                  .isEmployeeInScope(
                    worker['id'] as String,
                    session?.toIds ?? const [],
                  );
              if (!mounted || !context.mounted) return;
              if (!isInScope) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Nhân viên không thuộc phạm vi tổ được phân quyền.',
                    ),
                    backgroundColor: CaslaColors.danger,
                  ),
                );
                return;
              }
              if (mounted) {
                Navigator.pop(context); // Pop camera page
                setState(() {
                  _selectedWorker = worker;
                });
              }
            },
          ),
        ),
      ),
    );
  }

  void _scanProductQR() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          body: QrScannerView(
            title: 'Quét mã sản phẩm / NVL',
            subtitle:
                'Đưa mã QR trên lô sản phẩm hoặc thẻ đơn hàng vào khung hình.',
            onManualInput: () => _showManualOrderSelection(isFromCamera: true),
            onScan: (code) async {
              final db = ref.read(appStateProvider).db;
              final order = await db.getOrderByCode(code);
              if (!context.mounted || !mounted) return;
              if (order == null) {
                // Check if it's a worker QR by mistake
                final possibleWorker = await db.getEmployeeByCode(code);
                if (!context.mounted || !mounted) return;
                final msg = possibleWorker != null
                    ? 'Mã QR này là của Nhân viên (${possibleWorker['ten']}), không phải mã Sản phẩm.'
                    : 'Không tìm thấy sản phẩm có mã QR: $code';
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(msg),
                    backgroundColor: CaslaColors.danger,
                  ),
                );
                return;
              }
              Navigator.pop(context); // Pop camera page on success
              setState(() {
                _selectedOrder = order;
              });
            },
          ),
        ),
      ),
    );
  }

  void _showManualOrderSelection({bool isFromCamera = false}) async {
    final db = ref.read(appStateProvider).db;
    final openOrders = await db.getOpenOrders();

    if (!mounted) return;

    // Selection is handled by the onTap callbacks inside the sheet, so the
    // sheet's own result future is intentionally not awaited.
    unawaited(
      showModalBottomSheet(
        context: context,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (bottomSheetContext) {
          return Container(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Chọn sản phẩm',
                  style: TextStyle(
                    fontFamily: 'Manrope',
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: CaslaColors.primaryNavy,
                  ),
                ),
                const SizedBox(height: 12),
                ListView.builder(
                  shrinkWrap: true,
                  itemCount: openOrders.length,
                  itemBuilder: (context, index) {
                    final o = openOrders[index];
                    return ListTile(
                      title: Text(
                        o['ten_sp'] ?? '',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(o['dac_tinh'] ?? ''),
                      onTap: () {
                        Navigator.pop(bottomSheetContext); // Pop bottom sheet
                        if (isFromCamera && mounted) {
                          Navigator.pop(context); // Pop camera page
                        }
                        setState(() {
                          _selectedOrder = o;
                        });
                      },
                    );
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _submitAssignment() async {
    if (_selectedWorker == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Vui lòng chọn công nhân'),
          backgroundColor: CaslaColors.danger,
        ),
      );
      return;
    }

    if (_selectedOrder == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Vui lòng quét mã QR sản phẩm / NVL'),
          backgroundColor: CaslaColors.danger,
        ),
      );
      return;
    }

    final qty = double.tryParse(_qtyController.text) ?? 0.0;
    if (qty <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Vui lòng nhập số lượng giao hợp lệ (> 0)'),
          backgroundColor: CaslaColors.danger,
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    final appState = ref.read(appStateProvider);
    final emp = appState.currentSession;

    final workerId = _selectedWorker!['id'] as String;
    final orderId = _selectedOrder!['id'] as String;
    final teamIds = (_selectedWorker!['to_ids'] as List?)?.cast<String>() ?? [];
    final allowedTeams = emp?.toIds.toSet() ?? const <String>{};
    String? toId;
    for (final teamId in teamIds) {
      if (allowedTeams.contains(teamId)) {
        toId = teamId;
        break;
      }
    }
    if (toId == null) {
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Công nhân không thuộc phạm vi tổ được phân quyền.'),
          backgroundColor: CaslaColors.danger,
        ),
      );
      return;
    }
    final createdBy = emp?.maNv ?? '';

    final dateFormatted = DateFormat('yyyy-MM-dd').format(_startDate);

    // Through the repository so the quantity check and the audit-log entry run.
    try {
      await appState.assignmentRepo.createAssignment(
        workerId: workerId,
        orderId: orderId,
        teamId: toId,
        assignedQuantity: qty,
        businessDate: dateFormatted,
        // Legacy field required by the current repository/SAP payload. Shift
        // selection is no longer part of the assignment workflow; keep the
        // previously used value until the backend contract makes it optional.
        shiftId: 'SHIFT_1',
        note: _noteController.text.trim().isEmpty
            ? null
            : _noteController.text.trim(),
        createdBy: createdBy,
      );
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString().replaceFirst(RegExp(r'^Exception:\s*'), ''),
          ),
          backgroundColor: CaslaColors.danger,
        ),
      );
      return;
    }

    if (!mounted) return;

    setState(() => _isSubmitting = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Đã giao ${qty.toStringAsFixed(0)} cái cho ${_selectedWorker!['ten']}',
        ),
        backgroundColor: CaslaColors.success,
      ),
    );

    if (Navigator.canPop(context)) {
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final workerDisplayName = _selectedWorker != null
        ? (_selectedWorker!['display'] ??
              '${_selectedWorker!['ma_nv']} ( ${_selectedWorker!['ten']} )')
        : 'Chọn hoặc quét mã công nhân';

    final productDisplayName = _selectedOrder != null
        ? '${_selectedOrder!['ten_sp']} (${_selectedOrder!['dac_tinh'] ?? ''})'
        : 'Quét mã QR sản phẩm / NVL';

    return Scaffold(
      backgroundColor: CaslaColors.background,
      appBar: AppBar(
        backgroundColor: CaslaColors.primaryNavy,
        foregroundColor: Colors.white,
        leading: Navigator.canPop(context)
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => context.pop(),
              )
            : null,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tạo phân công',
              style: TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w800,
                fontSize: 19,
              ),
            ),
            SizedBox(height: 2),
            Text(
              'Giao số lượng cho công nhân',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: CaslaColors.identityMeta,
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. Công nhân Field
                  RichText(
                    text: const TextSpan(
                      text: 'Công nhân ',
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
                  const SizedBox(height: 6),
                  InkWell(
                    onTap: _openWorkerPicker,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 13,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: CaslaColors.surface,
                        border: Border.all(color: CaslaColors.line, width: 1.5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              workerDisplayName,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: _selectedWorker != null
                                    ? CaslaColors.primaryNavy
                                    : CaslaColors.muted,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.qr_code_scanner,
                              size: 20,
                              color: CaslaColors.primaryNavy,
                            ),
                            onPressed: _scanWorkerQR,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    'Quét mã QR thẻ nhân viên để chọn công nhân giao NVL.',
                    style: TextStyle(fontSize: 10.5, color: CaslaColors.muted),
                  ),

                  const SizedBox(height: 16),

                  // 2. Sản phẩm (Quét mã QR) Field
                  RichText(
                    text: const TextSpan(
                      text: 'Sản phẩm ',
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
                  const SizedBox(height: 6),
                  InkWell(
                    onTap: _scanProductQR,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 13,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: CaslaColors.surface,
                        border: Border.all(
                          color: _selectedOrder != null
                              ? CaslaColors.gold700
                              : CaslaColors.line,
                          width: 1.5,
                          style: _selectedOrder == null
                              ? BorderStyle.solid
                              : BorderStyle.solid,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              productDisplayName,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: _selectedOrder != null
                                    ? CaslaColors.primaryNavy
                                    : CaslaColors.muted,
                              ),
                            ),
                          ),
                          const Icon(
                            Icons.qr_code_scanner,
                            size: 20,
                            color: CaslaColors.gold700,
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // 3. Số lượng giao Field
                  RichText(
                    text: const TextSpan(
                      text: 'Số lượng giao ',
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
                  const SizedBox(height: 6),
                  TextField(
                    controller: _qtyController,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(
                      fontFamily: 'Manrope',
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                      color: CaslaColors.primaryNavy,
                    ),
                    decoration: const InputDecoration(
                      suffixText: 'cái',
                      suffixStyle: TextStyle(
                        fontSize: 13,
                        color: CaslaColors.muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // 4. Ngày bắt đầu Field
                  RichText(
                    text: const TextSpan(
                      text: 'Ngày bắt đầu ',
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
                  const SizedBox(height: 6),
                  InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _startDate,
                        firstDate: DateTime(2026, 1, 1),
                        lastDate: DateTime(2027, 12, 31),
                      );
                      if (picked != null) {
                        setState(() {
                          _startDate = picked;
                        });
                      }
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 13,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: CaslaColors.surface,
                        border: Border.all(color: CaslaColors.line, width: 1.5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            DateFormat('dd/MM/yyyy').format(_startDate),
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: CaslaColors.primaryNavy,
                            ),
                          ),
                          const Icon(
                            Icons.calendar_today_outlined,
                            size: 18,
                            color: CaslaColors.primaryNavy,
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // 5. Ghi chú Field
                  const Text(
                    'Ghi chú',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: CaslaColors.primaryNavy,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _noteController,
                    decoration: const InputDecoration(
                      hintText: 'Không bắt buộc',
                      hintStyle: TextStyle(
                        color: CaslaColors.muted,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(18),
            child: ElevatedButton(
              onPressed: _isSubmitting ? null : _submitAssignment,
              child: _isSubmitting
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: CaslaColors.navy900,
                      ),
                    )
                  : const Text('Xác nhận phân công'),
            ),
          ),
        ],
      ),
    );
  }
}
