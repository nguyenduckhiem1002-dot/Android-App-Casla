// Screen S04 — Record Production
// Spec: Section 5.2 S04 (locked context, stat row, quantity keypad, CTA)

import 'package:flutter/material.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../app/theme/casla_typography.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/policies/shift_resolver.dart';
import '../../../shared/widgets/components.dart';

class RecordProductionScreen extends StatefulWidget {
  final UserSession userSession;
  final Assignment assignment;
  final VoidCallback onBack;
  final ValueChanged<double> onSubmitRecord;

  const RecordProductionScreen({
    super.key,
    required this.userSession,
    required this.assignment,
    required this.onBack,
    required this.onSubmitRecord,
  });

  @override
  State<RecordProductionScreen> createState() => _RecordProductionScreenState();
}

class _RecordProductionScreenState extends State<RecordProductionScreen> {
  String _quantityText = '';

  @override
  Widget build(BuildContext context) {
    final a = widget.assignment;
    final shift = ShiftResolver.getCurrentShiftInfo();
    final quantity = double.tryParse(_quantityText) ?? 0.0;
    final canSubmit = quantity > 0 && quantity <= a.remaining;

    return Scaffold(
      backgroundColor: CaslaColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Sub-header
            CaslaSubHeader(
              title: 'Ghi nhận sản lượng',
              subtitle: '${a.orderCode} · ${a.productName}',
              onBack: widget.onBack,
            ),

            // Content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    // Locked context info
                    LockedInfoCard(rows: {
                      'Công nhân': '${widget.userSession.fullName} (${widget.userSession.maNv})',
                      'Sản phẩm': a.productName,
                      'Đơn vị': a.uom,
                      'Ca / Ngày': '${shift.shiftName} · ${ShiftResolver.formatDateDisplay(shift.businessDate)}',
                    }),

                    const SizedBox(height: 14),

                    // Stat row
                    Row(
                      children: [
                        Expanded(child: KpiCard(
                          label: 'Giao hiệu lực',
                          value: a.effectiveAssigned.toInt().toString(),
                        )),
                        const SizedBox(width: 8),
                        Expanded(child: KpiCard(
                          label: 'Hoàn thành',
                          value: a.completedQuantity.toInt().toString(),
                        )),
                        const SizedBox(width: 8),
                        Expanded(child: KpiCard(
                          label: 'Còn lại',
                          value: a.remaining.toInt().toString(),
                          isAccent: true,
                        )),
                      ],
                    ),

                    const SizedBox(height: 10),

                    // Quantity keypad
                    QuantityKeypad(
                      valueText: _quantityText,
                      uom: a.uom,
                      onValueChange: (v) => setState(() => _quantityText = v),
                      onQuickAdd: (amount) {
                        final current = int.tryParse(_quantityText) ?? 0;
                        setState(() => _quantityText = (current + amount).toString());
                      },
                    ),
                  ],
                ),
              ),
            ),

            // CTA Button
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
              decoration: const BoxDecoration(
                color: CaslaColors.surface,
                border: Border(top: BorderSide(color: CaslaColors.line)),
              ),
              child: Column(
                children: [
                  if (quantity > a.remaining && _quantityText.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        'Số lượng vượt quá còn lại (${a.remaining.toInt()})',
                        style: const TextStyle(fontSize: 12, color: CaslaColors.danger, fontWeight: FontWeight.w600),
                      ),
                    ),
                  CaslaPrimaryButton(
                    text: 'Lưu ghi nhận',
                    onPressed: canSubmit ? () => widget.onSubmitRecord(quantity) : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
