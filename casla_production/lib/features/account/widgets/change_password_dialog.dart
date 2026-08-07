import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../data/sap/sap_auth_controller.dart';
import '../../../data/sap/sap_odata_client.dart';
import '../../../main.dart';

Future<void> showChangePasswordDialog(
  BuildContext context, {
  bool isMandatory = false,
  WidgetRef? ref,
  String? userUuid,
  String? accessToken,
}) async {
  final currentPasswordController = TextEditingController();
  final newPasswordController = TextEditingController();
  final confirmPasswordController = TextEditingController();

  bool obscureCurrent = true;
  bool obscureNew = true;
  bool obscureConfirm = true;
  String? errorText;
  bool isLoading = false;

  await showDialog(
    context: context,
    barrierDismissible: !isMandatory,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          final current = currentPasswordController.text.trim();
          final newPwd = newPasswordController.text.trim();
          final confirmPwd = confirmPasswordController.text.trim();

          // Validation Rules:
          // 1. All fields non-empty
          // 2. newPassword >= 8 characters
          // 3. confirmPassword == newPassword
          // 4. newPassword != current (new password cannot match old password)
          final isFormValid = current.isNotEmpty &&
              newPwd.length >= 8 &&
              confirmPwd == newPwd &&
              newPwd != current;

          Future<void> submitChangePassword() async {
            if (!isFormValid || isLoading) return;

            setState(() {
              isLoading = true;
              errorText = null;
            });

            try {
              final appSession = ref?.read(appStateProvider).currentSession;
              final finalUuid = (userUuid != null && userUuid.isNotEmpty)
                  ? userUuid
                  : (appSession?.id ?? '');
              final finalToken = (accessToken != null && accessToken.isNotEmpty)
                  ? accessToken
                  : (appSession?.accessToken ?? '');

              if (finalUuid.isEmpty || finalUuid.startsWith('sap-')) {
                setState(() {
                  isLoading = false;
                  errorText = 'Không tìm thấy User UUID hợp lệ. Vui lòng đăng nhập lại.';
                });
                return;
              }

              final sapAuth = SapAuthController(SapODataClient());
              await sapAuth.changePassword(
                userUuid: finalUuid,
                accessToken: finalToken,
                oldPassword: current,
                newPassword: newPwd,
              );

              if (!context.mounted) return;

              Navigator.of(dialogContext).pop();

              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Cập nhật mật khẩu SAP thành công!'),
                  backgroundColor: CaslaColors.success,
                ),
              );
            } catch (e) {
              if (!context.mounted) return;
              setState(() {
                isLoading = false;
                errorText = e.toString().replaceAll('Exception: ', '');
              });
            }
          }

          // Compute dynamic hint or error warning text
          String? helperWarning;
          if (current.isNotEmpty && newPwd.isNotEmpty) {
            if (newPwd == current) {
              helperWarning = 'Mật khẩu mới không được trùng với mật khẩu cũ';
            } else if (newPwd.length < 8) {
              helperWarning = 'Mật khẩu mới phải có ít nhất 8 ký tự';
            } else if (confirmPwd.isNotEmpty && confirmPwd != newPwd) {
              helperWarning = 'Mật khẩu xác nhận không khớp';
            }
          }

          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
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
                    color: isMandatory
                        ? CaslaColors.gold700
                        : CaslaColors.primaryNavy,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    isMandatory ? 'Yêu cầu đổi mật khẩu' : 'Đổi mật khẩu SAP',
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
                  if (isMandatory) ...[
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: CaslaColors.gold100,
                        border: Border.all(color: CaslaColors.accentGold),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.info_outline,
                              size: 18, color: CaslaColors.gold700),
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
                  const Text('Mật khẩu hiện tại',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: CaslaColors.primaryNavy)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: currentPasswordController,
                    obscureText: obscureCurrent,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Nhập mật khẩu hiện tại',
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscureCurrent
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 18,
                        ),
                        onPressed: () {
                          setState(() {
                            obscureCurrent = !obscureCurrent;
                          });
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // New password
                  const Text('Mật khẩu mới',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: CaslaColors.primaryNavy)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: newPasswordController,
                    obscureText: obscureNew,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Tối thiểu 8 ký tự',
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscureNew
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 18,
                        ),
                        onPressed: () {
                          setState(() {
                            obscureNew = !obscureNew;
                          });
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Confirm password
                  const Text('Xác nhận mật khẩu mới',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: CaslaColors.primaryNavy)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: confirmPasswordController,
                    obscureText: obscureConfirm,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Nhập lại mật khẩu mới',
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscureConfirm
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 18,
                        ),
                        onPressed: () {
                          setState(() {
                            obscureConfirm = !obscureConfirm;
                          });
                        },
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

                  if (errorText != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      errorText!,
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
              if (!isMandatory)
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Hủy',
                      style: TextStyle(color: CaslaColors.muted)),
                ),
              ElevatedButton(
                onPressed: (isFormValid && !isLoading)
                    ? submitChangePassword
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: CaslaColors.primaryNavy,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: CaslaColors.primaryNavy.withOpacity(0.4),
                  disabledForegroundColor: Colors.white70,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  elevation: isFormValid ? 2 : 0,
                ),
                child: isLoading
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
        },
      );
    },
  );
}
