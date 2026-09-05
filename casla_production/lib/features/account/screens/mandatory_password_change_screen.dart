import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/casla_colors.dart';
import '../../../main.dart';
import '../widgets/change_password_dialog.dart';

/// The only route available to an SAP session flagged `PasswordChangeRequired`.
/// A route-level gate is stronger than showing an optional dialog over a live
/// shell: Android back, deep links and an unmounted shell cannot bypass it.
class MandatoryPasswordChangeScreen extends ConsumerStatefulWidget {
  const MandatoryPasswordChangeScreen({super.key});

  @override
  ConsumerState<MandatoryPasswordChangeScreen> createState() =>
      _MandatoryPasswordChangeScreenState();
}

class _MandatoryPasswordChangeScreenState
    extends ConsumerState<MandatoryPasswordChangeScreen> {
  bool _dialogOpened = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _openDialog());
  }

  Future<void> _openDialog() async {
    if (!mounted || _dialogOpened) return;
    _dialogOpened = true;
    await showChangePasswordDialog(context, isMandatory: true, ref: ref);
    // The mandatory dialog normally exits only after logout. If its host was
    // rebuilt during that transition, a still-valid mandatory session gets a
    // fresh prompt instead of access to any protected screen.
    if (mounted &&
        ref.read(appStateProvider).currentSession?.passwordChangeRequired ==
            true) {
      _dialogOpened = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _openDialog());
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: CaslaColors.background,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: CaslaColors.gold100,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(
                        Icons.lock_reset_rounded,
                        size: 34,
                        color: CaslaColors.gold700,
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Cần đổi mật khẩu',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Manrope',
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                        color: CaslaColors.primaryNavy,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'SAP yêu cầu đổi mật khẩu trước khi tiếp tục sử dụng ứng dụng.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: CaslaColors.muted, height: 1.5),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: _openDialog,
                      icon: const Icon(Icons.lock_reset_rounded),
                      label: const Text('Đổi mật khẩu ngay'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
