import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../app/theme/casla_colors.dart';

class QrScannerView extends StatefulWidget {
  final String title;
  final String subtitle;
  final String? deviceLabel;
  final VoidCallback? onManualInput;
  final Function(String code) onScan;

  const QrScannerView({
    super.key,
    required this.title,
    required this.subtitle,
    this.deviceLabel,
    this.onManualInput,
    required this.onScan,
  });

  @override
  State<QrScannerView> createState() => _QrScannerViewState();
}

class _QrScannerViewState extends State<QrScannerView>
    with SingleTickerProviderStateMixin {
  final MobileScannerController controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
    torchEnabled: false,
  );

  late AnimationController _animController;
  late Animation<double> _scanAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);

    _scanAnimation = Tween<double>(begin: 14.0, end: 196.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    controller.dispose();
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Camera feed
        MobileScanner(
          controller: controller,
          onDetect: (capture) {
            final barcodes = capture.barcodes;
            for (final barcode in barcodes) {
              if (barcode.rawValue != null) {
                widget.onScan(barcode.rawValue!);
                break;
              }
            }
          },
        ),

        // Transparent overlay container for clear camera view

        // UI Overlay Content
        SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 16),
              // Brand Logo Header
              Column(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [CaslaColors.accentGold, CaslaColors.gold700],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      'CG',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                        color: CaslaColors.navy900,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'CASLA GROUP',
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      letterSpacing: 1.0,
                      color: Colors.white,
                    ),
                  ),
                  const Text(
                    'GHI NHẬN SẢN LƯỢNG',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 9.5,
                      color: Color(0xFF6B76A3),
                    ),
                  ),
                ],
              ),

              const Spacer(),

              // Viewfinder frame
              Center(
                child: SizedBox(
                  width: 210,
                  height: 210,
                  child: Stack(
                    children: [
                      // Top Left Corner
                      Positioned(
                        top: 0,
                        left: 0,
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: const BoxDecoration(
                            border: Border(
                              top: BorderSide(color: CaslaColors.accentGold, width: 4),
                              left: BorderSide(color: CaslaColors.accentGold, width: 4),
                            ),
                            borderRadius: BorderRadius.only(topLeft: Radius.circular(10)),
                          ),
                        ),
                      ),
                      // Top Right Corner
                      Positioned(
                        top: 0,
                        right: 0,
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: const BoxDecoration(
                            border: Border(
                              top: BorderSide(color: CaslaColors.accentGold, width: 4),
                              right: BorderSide(color: CaslaColors.accentGold, width: 4),
                            ),
                            borderRadius: BorderRadius.only(topRight: Radius.circular(10)),
                          ),
                        ),
                      ),
                      // Bottom Left Corner
                      Positioned(
                        bottom: 0,
                        left: 0,
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: const BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: CaslaColors.accentGold, width: 4),
                              left: BorderSide(color: CaslaColors.accentGold, width: 4),
                            ),
                            borderRadius: BorderRadius.only(bottomLeft: Radius.circular(10)),
                          ),
                        ),
                      ),
                      // Bottom Right Corner
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: const BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: CaslaColors.accentGold, width: 4),
                              right: BorderSide(color: CaslaColors.accentGold, width: 4),
                            ),
                            borderRadius: BorderRadius.only(bottomRight: Radius.circular(10)),
                          ),
                        ),
                      ),

                      // Laser Scan Line
                      AnimatedBuilder(
                        animation: _scanAnimation,
                        builder: (context, child) {
                          return Positioned(
                            top: _scanAnimation.value,
                            left: 8,
                            right: 8,
                            child: Container(
                              height: 2,
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Colors.transparent,
                                    CaslaColors.accentGold,
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 26),

              // Title & Subtitle
              Text(
                widget.title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'Manrope',
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  widget.subtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: Color(0xFF93A0CC),
                    height: 1.5,
                  ),
                ),
              ),

              if (widget.onManualInput != null) ...[
                const SizedBox(height: 20),
                TextButton(
                  onPressed: widget.onManualInput,
                  child: const Text(
                    'Nhập bằng tay',
                    style: TextStyle(
                      color: CaslaColors.accentGold,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],

              const Spacer(),

              // Footer Label
              Text(
                widget.deviceLabel ?? 'THIẾT BỊ · PDA-CT02-A17 · v1.0.0',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 9.5,
                  color: Color(0xFF5C6690),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),

        // Floating Back Button (Top Left)
        if (Navigator.canPop(context))
          Positioned(
            top: 12,
            left: 12,
            child: SafeArea(
              child: Material(
                color: Colors.black45,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => Navigator.pop(context),
                  child: const Padding(
                    padding: EdgeInsets.all(10.0),
                    child: Icon(
                      Icons.arrow_back,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
