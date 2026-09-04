import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../core/config/app_config.dart';
import '../../../core/utils/device_info.dart';
import '../../../data/sap/sap_auth_controller.dart';
import '../../../data/sap/sap_odata_client.dart';
import '../../../main.dart';

Future<void> showChangePasswordDialog(
  BuildContext context, {
  bool isMandatory = false,
  WidgetRef? ref,
  String? userUuid,
  String? accessToken,
}) {
  return showDialog(
    context: context,
    barrierDismissible: !isMandatory,
    builder: (dialogContext) => _ChangePasswordDialog(
      hostContext: context,
      isMandatory: isMandatory,
      ref: ref,
      accessToken: accessToken,
    ),
  );
}

class _ChangePasswordDialog extends StatefulWidget {
  /// The screen that opened this dialog — used for the success SnackBar,
  /// which must outlive the dialog's own (about-to-be-popped) context.
  final BuildContext hostContext;
  final bool isMandatory;
  final WidgetRef? ref;
  final String? accessToken;

  const _ChangePasswordDialog({
    required this.hostContext,
    required this.isMandatory,
    this.ref,
    this.accessToken,
  });

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
    final current = _currentPasswordController.text.trim();
    final newPwd = _newPasswordController.text.trim();
    final confirmPwd = _confirmPasswordController.text.trim();
    final isFormValid =
        current.isNotEmpty &&
        newPwd.isNotEmpty &&
        confirmPwd == newPwd &&
        newPwd != current;

    if (!isFormValid || _isLoading) return;

    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      final appSession = widget.ref?.read(appStateProvider).currentSession;
      final finalToken =
          (widget.accessToken != null && widget.accessToken!.isNotEmpty)
          ? widget.accessToken!
          : (appSession?.accessToken ?? '');

      if (finalToken.isEmpty) {
        setState(() {
          _isLoading = false;
          _errorText =
              'Không tìm thấy phiên đăng nhập hợp lệ. Vui lòng đăng nhập lại.';
        });
        return;
      }

      final sapAuth = SapAuthController(
        SapODataClient(baseUrl: AppConfig.sapAuthServiceUrl),
      );
      await sapAuth.changePassword(
        accessToken: finalToken,
        currentPassword: current,
        newPassword: newPwd,
        deviceId: await DeviceInfoHelper.getDeviceId(),
      );

      if (!mounted) return;
      Navigator.of(context).pop();

      if (!widget.hostContext.mounted) return;
      ScaffoldMessenger.of(widget.hostContext).showSnackBar(
        const SnackBar(
          content: Text('Cập nhật mật khẩu SAP thành công!'),
          backgroundColor: CaslaColors.success,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorText = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = _currentPasswordController.text.trim();
    final newPwd = _newPasswordController.text.trim();
    final confirmPwd = _confirmPasswordController.text.trim();
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

    return AlertDialog(
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
              widget.isMandatory ? 'Yêu cầu đổi mật khẩu' : 'Đổi mật khẩu SAP',
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
              obscureText: _obscureCurrent,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Nhập mật khẩu hiện tại',
                suffixIcon: IconButton(
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
              obscureText: _obscureNew,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Nhập mật khẩu mới',
                suffixIcon: IconButton(
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
              obscureText: _obscureConfirm,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Nhập lại mật khẩu mới',
                suffixIcon: IconButton(
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
              Text(
                _errorText!,
                style: const TextStyle(
                  color: CaslaColors.danger,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (!widget.isMandatory)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'Hủy',
              style: TextStyle(color: CaslaColors.muted),
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
    );
  }
}
