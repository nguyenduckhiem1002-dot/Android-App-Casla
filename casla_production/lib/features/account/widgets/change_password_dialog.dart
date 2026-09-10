import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../core/config/app_config.dart';
import '../../../core/utils/device_info.dart';
import '../../../data/sap/sap_auth_controller.dart';
import '../../../data/sap/sap_odata_client.dart';
import '../../../main.dart';

final passwordChangeControllerProvider = Provider<SapAuthController>((ref) {
  final client = SapODataClient(baseUrl: AppConfig.sapAuthServiceUrl);
  ref.onDispose(() => client.dio.close());
  return SapAuthController(client);
});

enum _PasswordDialogResult { loginRequired }

Future<void> showChangePasswordDialog(
  BuildContext context, {
  bool isMandatory = false,
  required WidgetRef ref,
}) async {
  // Capture dependencies while the host is mounted. The mandatory host awaits
  // this entire flow, so it must not reopen its prompt between success/logout.
  final appState = ref.read(appStateProvider);
  final router = GoRouter.of(context);
  final result = await showDialog<_PasswordDialogResult>(
    context: context,
    barrierDismissible: !isMandatory,
    builder: (dialogContext) =>
        _ChangePasswordDialog(isMandatory: isMandatory, ref: ref),
  );
  if (result == _PasswordDialogResult.loginRequired) {
    await appState.logout();
    router.go('/login');
  }
}

class _ChangePasswordDialog extends StatefulWidget {
  final bool isMandatory;
  final WidgetRef ref;

  const _ChangePasswordDialog({required this.isMandatory, required this.ref});

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _currentPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _obscureCurrent = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  String? _errorText;
  bool _isLoading = false;
  bool _passwordChanged = false;

  @override
  void dispose() {
    // Tied to this widget's own lifecycle rather than to showDialog's Future —
    // Navigator.pop() below resolves that Future (and used to run this dispose
    // via a `finally`) before the dialog's exit transition finishes animating,
    // while its TextFields are still mounted and rebuilding each frame. Disposing
    // here instead means the framework only calls it once this State itself is
    // unmounted, which happens after that transition completes.
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submitChangePassword() async {
    final current = _currentPasswordController.text;
    final newPwd = _newPasswordController.text;
    final confirmPwd = _confirmPasswordController.text;
    final isFormValid =
        current.isNotEmpty &&
        newPwd.isNotEmpty &&
        confirmPwd == newPwd &&
        newPwd != current;

    if (!isFormValid || _isLoading || _passwordChanged) return;

    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      final finalToken =
          widget.ref.read(appStateProvider).currentSession?.accessToken ?? '';

      if (finalToken.isEmpty) {
        setState(() {
          _isLoading = false;
          _errorText =
              'Không tìm thấy phiên đăng nhập hợp lệ. Vui lòng đăng nhập lại.';
        });
        return;
      }

      final sapAuth = widget.ref.read(passwordChangeControllerProvider);
      await sapAuth.changePassword(
        accessToken: finalToken,
        currentPassword: current,
        newPassword: newPwd,
        deviceId: await DeviceInfoHelper.getDeviceId(),
      );

      if (!mounted) return;
      FocusScope.of(context).unfocus();
      _currentPasswordController.clear();
      _newPasswordController.clear();
      _confirmPasswordController.clear();
      setState(() {
        _passwordChanged = true;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorText = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  // Keep success on the same route: popping the form early causes the
  // mandatory host to reopen it while PasswordChangeRequired is still true.
  Widget _buildSuccess() {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        scrollable: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text(
          'Đổi mật khẩu thành công',
          style: TextStyle(
            fontFamily: 'Manrope',
            fontWeight: FontWeight.w800,
            fontSize: 16,
            color: CaslaColors.primaryNavy,
          ),
        ),
        content: const Text(
          'Mật khẩu đã được cập nhật trên SAP. Vui lòng đăng nhập lại bằng mật khẩu mới.',
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: CaslaColors.primaryNavy,
              foregroundColor: Colors.white,
            ),
            onPressed: _finishWithLogin,
            child: const Text('Đăng nhập lại'),
          ),
        ],
      ),
    );
  }

  void _finishWithLogin() {
    // Explicit pop is permitted; PopScope blocks user back/maybePop only.
    Navigator.of(context).pop(_PasswordDialogResult.loginRequired);
  }

  @override
  Widget build(BuildContext context) {
    if (_passwordChanged) return _buildSuccess();
    final current = _currentPasswordController.text;
    final newPwd = _newPasswordController.text;
    final confirmPwd = _confirmPasswordController.text;
    final isFormValid =
        current.isNotEmpty &&
        newPwd.isNotEmpty &&
        confirmPwd == newPwd &&
        newPwd != current;

    // Compute dynamic hint or error warning text
    String? helperWarning;
    if (current.isNotEmpty && newPwd.isNotEmpty) {
      if (newPwd == current) {
        helperWarning = 'Mật khẩu mới không được trùng với mật khẩu cũ';
      } else if (confirmPwd.isNotEmpty && confirmPwd != newPwd) {
        helperWarning = 'Mật khẩu xác nhận không khớp';
      }
    }

    return PopScope(
      canPop: !widget.isMandatory && !_isLoading,
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: CaslaColors.gold100,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.lock_reset_rounded,
                color: widget.isMandatory
                    ? CaslaColors.gold700
                    : CaslaColors.primaryNavy,
                size: 24,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.isMandatory
                    ? 'Yêu cầu đổi mật khẩu'
                    : 'Đổi mật khẩu SAP',
                style: const TextStyle(
                  fontFamily: 'Manrope',
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  color: CaslaColors.primaryNavy,
                ),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.isMandatory) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: CaslaColors.gold100,
                    border: Border.all(color: CaslaColors.accentGold),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 18,
                        color: CaslaColors.gold700,
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Hệ thống yêu cầu bạn thay đổi mật khẩu lần đầu hoặc mật khẩu đã hết hạn.',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: CaslaColors.gold700,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // Current password
              const Text(
                'Mật khẩu hiện tại',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: CaslaColors.primaryNavy,
                ),
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _currentPasswordController,
                autofillHints: const [AutofillHints.password],
                autocorrect: false,
                enableSuggestions: false,
                obscureText: _obscureCurrent,
                textInputAction: TextInputAction.next,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Nhập mật khẩu hiện tại',
                  suffixIcon: IconButton(
                    tooltip: _obscureCurrent
                        ? 'Hiện mật khẩu hiện tại'
                        : 'Ẩn mật khẩu hiện tại',
                    icon: Icon(
                      _obscureCurrent
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 18,
                    ),
                    onPressed: () =>
                        setState(() => _obscureCurrent = !_obscureCurrent),
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // New password
              const Text(
                'Mật khẩu mới',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: CaslaColors.primaryNavy,
                ),
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _newPasswordController,
                autofillHints: const [AutofillHints.newPassword],
                autocorrect: false,
                enableSuggestions: false,
                obscureText: _obscureNew,
                textInputAction: TextInputAction.next,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Nhập mật khẩu mới',
                  suffixIcon: IconButton(
                    tooltip: _obscureNew
                        ? 'Hiện mật khẩu mới'
                        : 'Ẩn mật khẩu mới',
                    icon: Icon(
                      _obscureNew
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 18,
                    ),
                    onPressed: () => setState(() => _obscureNew = !_obscureNew),
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // Confirm password
              const Text(
                'Xác nhận mật khẩu mới',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: CaslaColors.primaryNavy,
                ),
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _confirmPasswordController,
                autofillHints: const [AutofillHints.newPassword],
                autocorrect: false,
                enableSuggestions: false,
                obscureText: _obscureConfirm,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submitChangePassword(),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Nhập lại mật khẩu mới',
                  suffixIcon: IconButton(
                    tooltip: _obscureConfirm
                        ? 'Hiện mật khẩu xác nhận'
                        : 'Ẩn mật khẩu xác nhận',
                    icon: Icon(
                      _obscureConfirm
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 18,
                    ),
                    onPressed: () =>
                        setState(() => _obscureConfirm = !_obscureConfirm),
                  ),
                ),
              ),

              if (helperWarning != null) ...[
                const SizedBox(height: 8),
                Text(
                  helperWarning,
                  style: const TextStyle(
                    color: CaslaColors.pending,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],

              if (_errorText != null) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _errorText!,
                    style: const TextStyle(
                      color: CaslaColors.danger,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _isLoading
                ? null
                : widget.isMandatory
                ? _finishWithLogin
                : () => Navigator.of(context).pop(),
            child: Text(
              widget.isMandatory ? 'Đăng xuất' : 'Hủy',
              style: const TextStyle(color: CaslaColors.muted),
            ),
          ),
          ElevatedButton(
            onPressed: (isFormValid && !_isLoading)
                ? _submitChangePassword
                : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: CaslaColors.primaryNavy,
              foregroundColor: Colors.white,
              disabledBackgroundColor: CaslaColors.primaryNavy.withValues(
                alpha: 0.4,
              ),
              disabledForegroundColor: Colors.white70,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              elevation: isFormValid ? 2 : 0,
            ),
            child: _isLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    'Xác nhận đổi mật khẩu',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
