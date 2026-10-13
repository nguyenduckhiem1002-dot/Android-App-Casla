import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/casla_colors.dart';
import '../../main.dart';

/// Opens the account screen from the top bar of every supervisor tab.
///
/// Account moved out of the bottom navigation to make room for Vị trí: it is
/// visited rarely during a shift, and the bar holds five items at most.
class AccountAvatarButton extends ConsumerWidget {
  /// Set when the avatar starts the top bar rather than ending it: its left
  /// edge then lines up with the page gutter rather than sitting inside an
  /// icon button's 8px inset, and the tap area extends towards the name.
  final bool leading;

  const AccountAvatarButton({super.key, this.leading = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(appStateProvider).currentSession;
    final name = session?.fullName.trim() ?? '';
    final label = name.isNotEmpty ? name : (session?.maNv ?? '');
    final tooltip = label.isEmpty ? 'Tài khoản' : 'Tài khoản: $label';
    final avatar = Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: CaslaColors.navy700,
        shape: BoxShape.circle,
        border: Border.all(color: CaslaColors.accentGold, width: 2),
      ),
      child: Text(
        initialsOf(label),
        style: const TextStyle(
          color: Colors.white,
          fontFamily: 'Manrope',
          fontSize: 13,
          fontWeight: FontWeight.w800,
        ),
      ),
    );

    if (leading) {
      return Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          label: tooltip,
          excludeSemantics: true,
          child: InkWell(
            onTap: () => context.push('/account'),
            borderRadius: BorderRadius.circular(24),
            // 48 x 48 hit area: the avatar flush left, the rest towards the
            // name, so the visible edge matches the cards below.
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 6, 12, 6),
              child: avatar,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: IconButton(
        tooltip: tooltip,
        onPressed: () => context.push('/account'),
        icon: avatar,
      ),
    );
  }

  /// `Trần Minh Khoa` → `MK`; a single word or a code gives its first two
  /// characters.
  static String initialsOf(String label) {
    final parts = label.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) {
      final word = parts.first.characters;
      return word.take(2).toString().toUpperCase();
    }
    return (parts[parts.length - 2].characters.first +
            parts.last.characters.first)
        .toUpperCase();
  }
}
