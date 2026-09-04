import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../main.dart';
import '../../../presentation/widgets/mutation_feedback.dart';
import '../../../presentation/widgets/qr_scanner_view.dart';
import '../../../presentation/widgets/worker_verification_dialog.dart';

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
  final TextEditingController _qtyController = TextEditingController();
  final TextEditingController _noteController = TextEditingController();
  DateTime _startDate = DateTime.now();
  bool _isSubmitting = false;
  String? _quantityError;

  @override
  void dispose() {
    _qtyController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _openWorkerPicker() {
    _showManualWorkerSelection();
  }

  void _scanWorkerQR() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          body: QrScannerView(
            title: 'Quét mã QR công nhân',
            subtitle: 'Đưa thẻ nhân viên vào khung hình.',
            onManualInput: () => _showManualWorkerSelection(isFromCamera: true),
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

  Future<void> _showManualWorkerSelection({bool isFromCamera = false}) async {
    final appState = ref.read(appStateProvider);
    final workers = await appState.db.getEmployeesByTeamIds(
      appState.currentSession?.toIds ?? const <String>[],
    );
    if (!mounted) return;

    final worker = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _SearchablePickerSheet(
        title: 'Chọn công nhân',
        searchHint: 'Tìm theo tên hoặc mã nhân viên',
        emptyMessage: 'Không có công nhân trong phạm vi được phân quyền.',
        items: workers,
        itemTitle: (item) => item['ten']?.toString() ?? 'Công nhân',
        itemSubtitle: (item) {
          final code = item['ma_nv']?.toString() ?? '';
          final department = item['bo_phan']?.toString() ?? '';
          return [
            code,
            department,
          ].where((value) => value.isNotEmpty).join(' · ');
        },
        searchableText: (item) => [
          item['ten'],
          item['ma_nv'],
          item['bo_phan'],
        ].whereType<Object>().join(' '),
      ),
    );
    if (!mounted || worker == null) return;

    if (isFromCamera && Navigator.canPop(context)) {
      Navigator.pop(context);
    }
    setState(() => _selectedWorker = worker);
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

  Future<void> _showManualOrderSelection({bool isFromCamera = false}) async {
    final db = ref.read(appStateProvider).db;
    final openOrders = await db.getOpenOrders();

    if (!mounted) return;
    final order = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _SearchablePickerSheet(
        title: 'Chọn sản phẩm',
        searchHint: 'Tìm theo sản phẩm, mã hoặc đơn hàng',
        emptyMessage: 'Hiện không có đơn hàng nào đang mở.',
        items: openOrders,
        itemTitle: (item) => item['ten_sp']?.toString() ?? 'Sản phẩm',
        itemSubtitle: (item) => [
          item['ma_sp'],
          item['ma_don_hang'],
          item['dac_tinh'],
        ].whereType<Object>().join(' · '),
        searchableText: (item) => [
          item['ten_sp'],
          item['ma_sp'],
          item['ma_don_hang'],
          item['ma_qr'],
          item['dac_tinh'],
        ].whereType<Object>().join(' '),
      ),
    );
    if (!mounted || order == null) return;

    if (isFromCamera && Navigator.canPop(context)) {
      Navigator.pop(context);
    }
    setState(() => _selectedOrder = order);
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
      setState(() => _quantityError = 'Số lượng giao phải lớn hơn 0.');
      return;
    }
    setState(() => _quantityError = null);

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
    final workerPassword = await showWorkerVerificationDialog(
      context,
      workerName: _selectedWorker!['ten'] as String? ?? 'Công nhân',
      actionLabel: 'gửi phân công lên SAP',
    );
    if (!mounted || workerPassword == null) return;

    setState(() => _isSubmitting = true);

    // Through the repository so the quantity check and the audit-log entry run.
    try {
      final receipt = await appState.assignmentRepo.createAssignment(
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
        workerPassword: workerPassword,
      );

      if (!mounted) return;
      showMutationFeedback(
        context,
        receipt: receipt,
        successMessage:
            'Đã giao ${qty.toStringAsFixed(0)} cái cho ${_selectedWorker!['ten']}.',
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
                            tooltip: 'Quét mã QR công nhân',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    'Chọn trong danh sách hoặc quét QR trên thẻ nhân viên.',
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
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (_) {
                      if (_quantityError != null) {
                        setState(() => _quantityError = null);
                      }
                    },
                    style: const TextStyle(
                      fontFamily: 'Manrope',
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                      color: CaslaColors.primaryNavy,
                    ),
                    decoration: InputDecoration(
                      errorText: _quantityError,
                      suffixText: 'cái',
                      suffixStyle: const TextStyle(
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
                      final now = DateTime.now();
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _startDate,
                        firstDate: DateTime(now.year - 2, 1, 1),
                        lastDate: DateTime(now.year + 2, 12, 31),
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

class _SearchablePickerSheet extends StatefulWidget {
  final String title;
  final String searchHint;
  final String emptyMessage;
  final List<Map<String, dynamic>> items;
  final String Function(Map<String, dynamic> item) itemTitle;
  final String Function(Map<String, dynamic> item) itemSubtitle;
  final String Function(Map<String, dynamic> item) searchableText;

  const _SearchablePickerSheet({
    required this.title,
    required this.searchHint,
    required this.emptyMessage,
    required this.items,
    required this.itemTitle,
    required this.itemSubtitle,
    required this.searchableText,
  });

  @override
  State<_SearchablePickerSheet> createState() => _SearchablePickerSheetState();
}

class _SearchablePickerSheetState extends State<_SearchablePickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final normalizedQuery = _query.trim().toLowerCase();
    final filtered = normalizedQuery.isEmpty
        ? widget.items
        : widget.items
              .where(
                (item) => widget
                    .searchableText(item)
                    .toLowerCase()
                    .contains(normalizedQuery),
              )
              .toList();

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 18,
          top: 18,
          right: 18,
          bottom: 18 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.68,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                style: const TextStyle(
                  fontFamily: 'Manrope',
                  fontWeight: FontWeight.w800,
                  fontSize: 17,
                  color: CaslaColors.primaryNavy,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _searchController,
                autofocus: widget.items.length > 8,
                textInputAction: TextInputAction.search,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  hintText: widget.searchHint,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Xóa nội dung tìm kiếm',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                          icon: const Icon(Icons.close),
                        ),
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            normalizedQuery.isEmpty
                                ? widget.emptyMessage
                                : 'Không tìm thấy kết quả phù hợp.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: CaslaColors.muted,
                              height: 1.4,
                            ),
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: filtered.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final item = filtered[index];
                          final subtitle = widget.itemSubtitle(item);
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              widget.itemTitle(item),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: subtitle.isEmpty
                                ? null
                                : Text(
                                    subtitle,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.pop(context, item),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
