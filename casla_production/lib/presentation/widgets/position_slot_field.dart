import 'package:flutter/material.dart';

import '../../app/theme/casla_colors.dart';
import '../../app/theme/casla_spacing.dart';
import 'scan_slot_field.dart';

/// Where the position in [PositionSlotField] came from.
enum PositionSource {
  /// The worker's seat on the position board.
  origin,

  /// Scanned at the machine: the worker operates there for now only.
  temporary,
}

/// What the lookup of the worker's seat is doing.
enum PositionLookupState { idle, loading, found, none, failed }

/// Optional "Vị trí / mã máy" field of the assignment form.
///
/// Laid out like [ScanSlotField] so the form keeps one rhythm, but filled in
/// a single line (`Mã vị trí: G05   Mã máy: M105`). Green means the worker's
/// own seat, amber a temporary one scanned at another machine.
class PositionSlotField extends StatelessWidget {
  final bool enabled;
  final bool isScanTarget;
  final VoidCallback onSelect;
  final VoidCallback onOpenScanner;
  final VoidCallback? onClear;

  final String? positionId;
  final String? machineId;
  final PositionSource source;
  final PositionLookupState lookup;

  /// The worker's own seat, offered as a way back from a temporary one.
  final String? originPositionId;
  final VoidCallback? onUseOrigin;

  /// Why the current choice cannot be sent, shown under the field.
  final String? errorText;

  const PositionSlotField({
    super.key,
    required this.enabled,
    required this.isScanTarget,
    required this.onSelect,
    required this.onOpenScanner,
    required this.onClear,
    required this.positionId,
    required this.machineId,
    required this.source,
    required this.lookup,
    this.originPositionId,
    this.onUseOrigin,
    this.errorText,
  });

  bool get _filled => (positionId ?? '').isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final temporary = _filled && source == PositionSource.temporary;
    final background = !_filled
        ? CaslaColors.surface
        : temporary
        ? CaslaColors.pendingBg
        : CaslaColors.successBg;
    final border = isScanTarget
        ? CaslaColors.primaryNavy
        : errorText != null
        ? CaslaColors.danger
        : !_filled
        ? CaslaColors.line
        : temporary
        ? CaslaColors.pending
        : CaslaColors.success;

    final hint = switch (lookup) {
      _ when _filled => null,
      PositionLookupState.loading =>
        'Đang lấy vị trí hiện tại của công nhân từ SAP…',
      PositionLookupState.none =>
        'Công nhân chưa được xếp vị trí. Quét nhãn trên máy nếu đang ngồi '
            'máy nào.',
      PositionLookupState.failed =>
        'Không lấy được vị trí từ SAP. Vẫn giao được; quét nhãn trên máy để '
            'ghi vị trí.',
      _ => null,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: ScanFieldLabel(text: 'Vị trí / mã máy')),
            if (isScanTarget)
              const Text(
                'Đang chọn quét',
                style: TextStyle(
                  color: CaslaColors.primaryNavy,
                  fontSize: CaslaType.caption,
                  fontWeight: FontWeight.w700,
                ),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                decoration: BoxDecoration(
                  color: CaslaColors.muted100,
                  borderRadius: BorderRadius.circular(CaslaRadius.pill),
                ),
                child: const Text(
                  'Tùy chọn',
                  style: TextStyle(
                    color: CaslaColors.muted,
                    fontSize: CaslaType.caption,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: CaslaSpacing.xs),
        Material(
          color: background,
          shape: RoundedRectangleBorder(
            side: BorderSide(color: border, width: isScanTarget ? 2 : 1.2),
            borderRadius: BorderRadius.circular(CaslaRadius.md),
          ),
          child: InkWell(
            onTap: enabled ? onSelect : null,
            borderRadius: BorderRadius.circular(CaslaRadius.md),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                CaslaSpacing.sm,
                CaslaSpacing.xxs,
                CaslaSpacing.xxs,
                CaslaSpacing.xxs,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        !_filled
                            ? Icons.place_outlined
                            : temporary
                            ? Icons.swap_horiz_rounded
                            : Icons.check_circle_rounded,
                        size: 22,
                        color: !_filled
                            ? CaslaColors.muted
                            : temporary
                            ? CaslaColors.pending
                            : CaslaColors.success,
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: _value()),
                      if (onClear != null && _filled)
                        IconButton(
                          tooltip: 'Xóa vị trí',
                          onPressed: onClear,
                          icon: const Icon(Icons.close, size: 20),
                          color: CaslaColors.muted,
                          constraints: const BoxConstraints(
                            minWidth: 44,
                            minHeight: 44,
                          ),
                        ),
                      IconButton(
                        tooltip: 'Quét nhãn vị trí',
                        onPressed: enabled ? onOpenScanner : null,
                        icon: const Icon(Icons.photo_camera_outlined, size: 22),
                        color: CaslaColors.primaryNavy,
                        constraints: const BoxConstraints(
                          minWidth: 44,
                          minHeight: 44,
                        ),
                      ),
                    ],
                  ),
                  if (lookup == PositionLookupState.loading && !_filled)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(32, 0, 12, 6),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  if (hint != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(32, 0, 12, 8),
                      child: Text(
                        hint,
                        style: TextStyle(
                          fontSize: CaslaType.caption,
                          height: 1.35,
                          color: lookup == PositionLookupState.failed
                              ? CaslaColors.pending
                              : CaslaColors.muted,
                        ),
                      ),
                    ),
                  if (errorText != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 0, 12, 8),
                      child: Semantics(
                        liveRegion: true,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.error_outline_rounded,
                              size: 18,
                              color: CaslaColors.danger,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(
                                errorText!,
                                style: const TextStyle(
                                  fontSize: CaslaType.caption,
                                  fontWeight: FontWeight.w600,
                                  height: 1.35,
                                  color: CaslaColors.danger,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (temporary &&
                      onUseOrigin != null &&
                      (originPositionId ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 24, bottom: 4),
                      child: TextButton.icon(
                        onPressed: onUseOrigin,
                        icon: const Icon(Icons.restart_alt_rounded, size: 18),
                        label: Text('Dùng vị trí gốc $originPositionId'),
                        style: TextButton.styleFrom(
                          foregroundColor: CaslaColors.primaryNavy,
                          textStyle: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _value() {
    if (!_filled) {
      return Text(
        enabled ? 'Chưa có vị trí' : 'Chọn công nhân trước',
        style: const TextStyle(
          fontSize: CaslaType.body,
          fontWeight: FontWeight.w700,
          color: CaslaColors.muted,
        ),
      );
    }
    // One line at normal code lengths; two 10-character codes on a narrow
    // handset wrap instead of being clipped.
    return Wrap(
      spacing: 10,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _pair('Mã vị trí:', positionId!),
        if ((machineId ?? '').isNotEmpty) _pair('Mã máy:', machineId!),
      ],
    );
  }

  static Widget _pair(String label, String value) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: '$label ',
          style: const TextStyle(
            fontSize: CaslaType.caption,
            fontWeight: FontWeight.w600,
            color: CaslaColors.muted,
          ),
        ),
        TextSpan(
          text: value,
          style: const TextStyle(
            fontSize: CaslaType.body,
            fontWeight: FontWeight.w700,
            color: CaslaColors.primaryNavy,
          ),
        ),
      ],
    ),
  );
}
