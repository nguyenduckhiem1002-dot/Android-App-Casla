import 'package:flutter/material.dart';

import '../../app/theme/casla_colors.dart';

/// Shown above a SAP report whose latest refresh failed while an earlier
/// snapshot (plus this device's unsynced writes) is still on screen.
class StaleHistoryBanner extends StatelessWidget {
  const StaleHistoryBanner({super.key});

  static const message =
      'Không thể làm mới từ SAP. Đang hiển thị dữ liệu gần nhất trên máy.';

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: CaslaColors.pendingBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Row(
        children: [
          Icon(
            Icons.cloud_off_outlined,
            color: CaslaColors.bannerText,
            size: 17,
          ),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: CaslaColors.bannerText, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
