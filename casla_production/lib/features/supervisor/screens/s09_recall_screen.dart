import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../main.dart';

class S09RecallScreen extends ConsumerStatefulWidget {
  final Map<String, dynamic> assignment;

  const S09RecallScreen({
    super.key,
    required this.assignment,
  });

  @override
  ConsumerState<S09RecallScreen> createState() => _S09RecallScreenState();
}

class _S09RecallScreenState extends ConsumerState<S09RecallScreen> {
  final TextEditingController _qtyController =
      TextEditingController(text: '80');
  final TextEditingController _noteController = TextEditingController();
  String _selectedReason = 'KHONG_LAM_HET';
  bool _isSubmitting = false;

  final Map<String, String> _reasons = {
    'KHONG_LAM_HET': 'Không làm hết',
    'DIEU_CHUYEN': 'Điều chuyển công nhân',
    'DOI_KE_HOACH': 'Đổi kế hoạch sản xuất',
    'KET_THUC_DON': 'Kết thúc đơn hàng',
    'KHAC': 'Khác',
  };

  @override
  void dispose() {
    _qtyController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _submitRecall(double maxRecall, double currentEffective) async {
    final qty = double.tryParse(_qtyController.text) ?? 0.0;
    if (qty <= 0 || qty > maxRecall) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Số lượng thu hồi phải > 0 và <= ${maxRecall.toStringAsFixed(0)}'),
          backgroundColor: CaslaColors.danger,
        ),
      );
      return;
    }

    if (_selectedReason == 'KHAC' && _noteController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Vui lòng nhập ghi chú khi chọn lý do Khác'),
          backgroundColor: CaslaColors.danger,
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    final appState = ref.read(appStateProvider);
    final emp = appState.currentSession;
    final supervisorMaNv = emp?.maNv ?? 'MNV00100';

    await appState.db.recordRecallOffline(
      assignmentId: widget.assignment['id'],
      quantity: qty,
      reason: _selectedReason,
      note: _noteController.text.trim().isEmpty
          ? null
          : _noteController.text.trim(),
      createdBy: supervisorMaNv,
      deviceId: 'PDA-CT02-A17',
    );

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Đã thu hồi -${qty.toStringAsFixed(0)} cái thành công'),
        backgroundColor: CaslaColors.success,
      ),
    );

    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    final asgId = widget.assignment['id'];

    return Scaffold(
      backgroundColor: CaslaColors.background,
      appBar: AppBar(
        backgroundColor: CaslaColors.primaryNavy,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Thu hồi phân công',
              style: TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w800,
                fontSize: 19,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${widget.assignment['don_hang_id']} · Nguyễn Văn A',
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
      body: FutureBuilder<List<dynamic>>(
        future: Future.wait([
          appState.db.getEffectiveAssigned(asgId),
          appState.db.getCompletedQuantity(asgId),
          appState.db.getRemaining(asgId),
        ]),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final effective = snapshot.data![0] as double;
          final completed = snapshot.data![1] as double;
          final maxRecall = snapshot.data![2] as double;

          final qtyInput = double.tryParse(_qtyController.text) ?? 0.0;
          final afterEffective = effective - qtyInput;
          final afterRemaining = maxRecall - qtyInput;

          return Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Quick Stats Row
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: CaslaColors.surface,
                          border: Border.all(color: CaslaColors.line),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _buildStatCol('Giao ban đầu',
                                effective.toStringAsFixed(0)),
                            _buildStatCol('Đã hoàn thành',
                                completed.toStringAsFixed(0)),
                            _buildStatCol(
                              'Có thể thu hồi',
                              maxRecall.toStringAsFixed(0),
                              color: CaslaColors.gold700,
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 16),

                      // Quantity input
                      const Text(
                        'Số lượng thu hồi *',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: CaslaColors.primaryNavy,
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _qtyController,
                        keyboardType: TextInputType.number,
                        onChanged: (v) => setState(() {}),
                        decoration: InputDecoration(
                          suffixText: '/ ${maxRecall.toStringAsFixed(0)} cái',
                          suffixStyle:
                              const TextStyle(color: CaslaColors.muted),
                        ),
                      ),

                      const SizedBox(height: 16),

                      // Reason Radio options
                      const Text(
                        'Lý do thu hồi *',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: CaslaColors.primaryNavy,
                        ),
                      ),
                      const SizedBox(height: 8),

                      Column(
                        children: _reasons.entries.map((entry) {
                          final isSelected = _selectedReason == entry.key;
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? CaslaColors.gold100
                                  : CaslaColors.surface,
                              border: Border.all(
                                color: isSelected
                                    ? CaslaColors.gold700
                                    : CaslaColors.line,
                                width: 1.5,
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: RadioListTile<String>(
                              value: entry.key,
                              groupValue: _selectedReason,
                              activeColor: CaslaColors.gold700,
                              title: Text(
                                entry.value,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: CaslaColors.primaryNavy,
                                ),
                              ),
                              onChanged: (val) {
                                if (val != null) {
                                  setState(() {
                                    _selectedReason = val;
                                  });
                                }
                              },
                            ),
                          );
                        }).toList(),
                      ),

                      if (_selectedReason == 'KHAC') ...[
                        const SizedBox(height: 10),
                        TextField(
                          controller: _noteController,
                          decoration: const InputDecoration(
                            hintText: 'Nhập lý do cụ thể...',
                          ),
                        ),
                      ],

                      const SizedBox(height: 16),

                      // Impact Preview Box
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: CaslaColors.dangerBg,
                          border: Border.all(color: const Color(0xFFF0C6C6)),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Giao hiệu lực',
                                  style: TextStyle(
                                      color: Color(0xFF7A1F1F), fontSize: 12),
                                ),
                                Text(
                                  '${effective.toStringAsFixed(0)} → ${afterEffective < 0 ? 0 : afterEffective.toStringAsFixed(0)}',
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF7A1F1F),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Còn lại sau thu hồi',
                                  style: TextStyle(
                                      color: Color(0xFF7A1F1F), fontSize: 12),
                                ),
                                Text(
                                  '${maxRecall.toStringAsFixed(0)} → ${afterRemaining < 0 ? 0 : afterRemaining.toStringAsFixed(0)}',
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF7A1F1F),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              Padding(
                padding: const EdgeInsets.all(18),
                child: ElevatedButton(
                  onPressed: _isSubmitting
                      ? null
                      : () => _submitRecall(maxRecall, effective),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: CaslaColors.danger,
                    foregroundColor: Colors.white,
                  ),
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Xác nhận thu hồi'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStatCol(String label, String value, {Color? color}) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: CaslaColors.muted),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontFamily: 'Manrope',
            fontWeight: FontWeight.w800,
            fontSize: 16,
            color: color ?? CaslaColors.primaryNavy,
          ),
        ),
      ],
    );
  }
}
