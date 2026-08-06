// Screen S07 — Create Assignment
// Spec: Section 5.2 S07 (Worker selection, order selection, quantity, date/shift)

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../app/theme/casla_typography.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/policies/shift_resolver.dart';
import '../../../shared/widgets/components.dart';

class CreateAssignmentScreen extends StatefulWidget {
  final List<Employee> availableWorkers;
  final VoidCallback onBack;
  final Function(String workerId, String productCode, double quantity, String? note) onSubmit;

  const CreateAssignmentScreen({
    super.key,
    required this.availableWorkers,
    required this.onBack,
    required this.onSubmit,
  });

  @override
  State<CreateAssignmentScreen> createState() => _CreateAssignmentScreenState();
}

class _CreateAssignmentScreenState extends State<CreateAssignmentScreen> {
  Employee? _selectedWorker;
  String? _scannedProduct;
  final _quantityController = TextEditingController();
  final _noteController = TextEditingController();
  final ShiftInfo _shift = ShiftResolver.getCurrentShiftInfo();

  @override
  void dispose() {
    _quantityController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_selectedWorker == null || _scannedProduct == null) return;
    final qty = double.tryParse(_quantityController.text) ?? 0.0;
    if (qty <= 0) return;

    widget.onSubmit(
      _selectedWorker!.id,
      _scannedProduct!,
      qty,
      _noteController.text.trim().isNotEmpty ? _noteController.text.trim() : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final qty = double.tryParse(_quantityController.text) ?? 0.0;
    final isValid = _selectedWorker != null && _scannedProduct != null && qty > 0;

    return Scaffold(
      backgroundColor: CaslaColors.background,
      body: SafeArea(
        child: Column(
          children: [
            CaslaSubHeader(
              title: 'Giao việc mới',
              onBack: widget.onBack,
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Date & Shift Context (locked)
                    LockedInfoCard(rows: {
                      'Ca / Ngày': '${_shift.shiftName} · ${ShiftResolver.formatDateDisplay(_shift.businessDate)}',
                    }),
                    const SizedBox(height: 24),

                    // Worker selection (Dropdown for MVP)
                    Text('1. Chọn công nhân', style: CaslaTypography.label),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<Employee>(
                      decoration: const InputDecoration(hintText: 'Chọn hoặc quét mã...'),
                      value: _selectedWorker,
                      items: widget.availableWorkers.map((w) => DropdownMenuItem(
                        value: w,
                        child: Text('${w.maNv} - ${w.fullName}'),
                      )).toList(),
                      onChanged: (v) => setState(() => _selectedWorker = v),
                    ),
                    const SizedBox(height: 20),

                    // Product QR Scan
                    Text('2. Sản phẩm', style: CaslaTypography.label),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        border: Border.all(color: CaslaColors.line),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _scannedProduct != null 
                                  ? 'SP: $_scannedProduct' 
                                  : 'Chưa quét mã sản phẩm',
                              style: TextStyle(
                                color: _scannedProduct != null ? CaslaColors.primaryNavy : CaslaColors.muted,
                                fontWeight: _scannedProduct != null ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                          ),
                          ElevatedButton.icon(
                            onPressed: () {
                              _showScannerModal(context);
                            },
                            icon: const Icon(Icons.qr_code_scanner, size: 18),
                            label: const Text('Quét QR'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: CaslaColors.navy100,
                              foregroundColor: CaslaColors.primaryNavy,
                              elevation: 0,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Quantity
                    Text('3. Số lượng giao', style: CaslaTypography.label),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _quantityController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        hintText: 'Nhập số lượng',
                        suffixText: 'cái',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 20),

                    // Note
                    Text('4. Ghi chú (tùy chọn)', style: CaslaTypography.label),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _noteController,
                      maxLines: 2,
                      decoration: const InputDecoration(hintText: 'Nhập ghi chú...'),
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
                text: 'Tạo phân công',
                onPressed: isValid ? _submit : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showScannerModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: CaslaColors.navy900,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Quét mã QR sản phẩm',
              style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white,
              ),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: MobileScanner(
                    onDetect: (capture) {
                      final barcodes = capture.barcodes;
                      if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
                        Navigator.pop(context);
                        setState(() {
                          _scannedProduct = barcodes.first.rawValue!;
                        });
                      }
                    },
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 32),
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  setState(() {
                    _scannedProduct = 'SP_${DateTime.now().millisecondsSinceEpoch.toString().substring(8)}';
                  });
                },
                icon: const Icon(Icons.bug_report),
                label: const Text('Mô phỏng Quét (Emulator)'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: CaslaColors.primaryNavy,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
