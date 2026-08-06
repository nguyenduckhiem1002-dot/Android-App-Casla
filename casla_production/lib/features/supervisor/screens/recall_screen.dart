// Screen S09 — Recall Screen
// Spec: Section 5.2 S09 (Recall action, max recall validation, reason code)

import 'package:flutter/material.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../app/theme/casla_typography.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/entities/enums.dart';
import '../../../domain/policies/production_math.dart';
import '../../../shared/widgets/components.dart';

class RecallScreen extends StatefulWidget {
  final Assignment assignment;
  final VoidCallback onBack;
  final Function(double quantity, String reasonCode, String? note) onSubmitRecall;

  const RecallScreen({
    super.key,
    required this.assignment,
    required this.onBack,
    required this.onSubmitRecall,
  });

  @override
  State<RecallScreen> createState() => _RecallScreenState();
}

class _RecallScreenState extends State<RecallScreen> {
  final _quantityController = TextEditingController();
  final _noteController = TextEditingController();
  RecallReason? _selectedReason;
  String? _errorMsg;

  @override
  void dispose() {
    _quantityController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _validateAndSubmit() {
    final a = widget.assignment;
    final qty = double.tryParse(_quantityController.text) ?? 0.0;
    
    final err = ProductionMath.validateRecallEntry(
      qty, a.maxRecall, _selectedReason?.code ?? '', _noteController.text,
    );

    if (_selectedReason == null) {
      setState(() => _errorMsg = 'Vui lòng chọn lý do thu hồi');
      return;
    }

    if (err != null) {
      setState(() => _errorMsg = err);
      return;
    }

    setState(() => _errorMsg = null);
    
    // Show confirmation dialog before submit (Spec 5.2 S09)
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xác nhận thu hồi'),
        content: Text('Bạn chắc chắn muốn thu hồi ${qty.toInt()} ${a.uom}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Hủy')),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              widget.onSubmitRecall(qty, _selectedReason!.code, _noteController.text);
            },
            child: const Text('Xác nhận', style: TextStyle(color: CaslaColors.danger)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.assignment;

    return Scaffold(
      backgroundColor: CaslaColors.background,
      body: SafeArea(
        child: Column(
          children: [
            CaslaSubHeader(
              title: 'Thu hồi phân công',
              subtitle: a.workerName,
              onBack: widget.onBack,
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Context
                    LockedInfoCard(rows: {
                      'Đơn hàng': a.orderCode,
                      'Sản phẩm': a.productName,
                      'Giao ban đầu': '${a.assignedQuantity.toInt()} ${a.uom}',
                      'Đã thu hồi trước đây': '${a.recalledQuantity.toInt()} ${a.uom}',
                      'Đã hoàn thành': '${a.completedQuantity.toInt()} ${a.uom}',
                    }),
                    
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: CaslaColors.dangerBg,
                        border: Border.all(color: CaslaColors.danger.withOpacity(0.3)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Có thể thu hồi tối đa:', style: TextStyle(fontWeight: FontWeight.w600, color: CaslaColors.danger)),
                          Text('${a.maxRecall.toInt()} ${a.uom}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: CaslaColors.danger)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Quantity input
                    Text('Số lượng thu hồi', style: CaslaTypography.label),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _quantityController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        hintText: 'Nhập số lượng',
                        suffixText: a.uom,
                      ),
                      onChanged: (_) => setState(() => _errorMsg = null),
                    ),
                    const SizedBox(height: 20),

                    // Reason selection
                    Text('Lý do thu hồi', style: CaslaTypography.label),
                    const SizedBox(height: 8),
                    ReasonPicker(
                      reasons: RecallReason.values,
                      selected: _selectedReason,
                      onSelected: (r) => setState(() {
                        _selectedReason = r;
                        _errorMsg = null;
                      }),
                    ),
                    const SizedBox(height: 16),

                    if (_selectedReason == RecallReason.other) ...[
                      Text('Ghi chú (bắt buộc)', style: CaslaTypography.label),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _noteController,
                        maxLines: 2,
                        decoration: const InputDecoration(hintText: 'Nhập ghi chú...'),
                        onChanged: (_) => setState(() => _errorMsg = null),
                      ),
                    ],

                    if (_errorMsg != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(_errorMsg!, style: const TextStyle(color: CaslaColors.danger, fontWeight: FontWeight.w600)),
                      ),
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
              decoration: const BoxDecoration(
                color: CaslaColors.surface,
                border: Border(top: BorderSide(color: CaslaColors.line)),
              ),
              child: CaslaPrimaryButton(
                text: 'Thu hồi',
                isDanger: true,
                onPressed: _validateAndSubmit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
