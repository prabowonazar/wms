import 'dart:async';

import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Panel kamera untuk SCR-03.
///
/// `MobileScanner` menangani siklus hidup aplikasi sendiri
/// (`useAppLifecycleState`), jadi kamera berhenti saat app ke background.
class ScannerPanel extends StatefulWidget {
  const ScannerPanel({
    super.key,
    required this.onCode,
    this.controller,
  });

  final ValueChanged<String> onCode;

  /// Dapat diisi fake controller pada test; bila null panel membuat sendiri.
  final MobileScannerController? controller;

  @override
  State<ScannerPanel> createState() => _ScannerPanelState();
}

class _ScannerPanelState extends State<ScannerPanel> {
  late final MobileScannerController _controller =
      widget.controller ??
          MobileScannerController(
            // Gudang memakai 1D (Code128/EAN) dan QR untuk label internal.
            formats: const <BarcodeFormat>[
              BarcodeFormat.code128,
              BarcodeFormat.code39,
              BarcodeFormat.ean13,
              BarcodeFormat.ean8,
              BarcodeFormat.upcA,
              BarcodeFormat.upcE,
              BarcodeFormat.qrCode,
            ],
            detectionSpeed: DetectionSpeed.noDuplicates,
          );
  late final bool _ownsController = widget.controller == null;

  bool _torchOn = false;

  @override
  void dispose() {
    if (_ownsController) {
      unawaited(_controller.dispose());
    }
    super.dispose();
  }

  void _handleCapture(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.trim().isNotEmpty) {
        widget.onCode(value);
        return;
      }
    }
  }

  Future<void> _toggleTorch() async {
    try {
      await _controller.toggleTorch();
      if (mounted) {
        setState(() => _torchOn = !_torchOn);
      }
    } catch (_) {
      // Sebagian device tidak punya flash; tombol tetap tidak fatal.
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _handleCapture,
            errorBuilder: (context, error) => _ScannerError(
              permissionDenied:
                  error.errorCode == MobileScannerErrorCode.permissionDenied,
            ),
            placeholderBuilder: (context) => const ColoredBox(
              color: Colors.black,
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 240,
                height: 140,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white70, width: 2),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          Positioned(
            right: 12,
            bottom: 12,
            child: FloatingActionButton.small(
              heroTag: null,
              tooltip: _torchOn ? 'Matikan lampu' : 'Nyalakan lampu',
              onPressed: _toggleTorch,
              child: Icon(_torchOn ? Icons.flash_on : Icons.flash_off),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScannerError extends StatelessWidget {
  const _ScannerError({required this.permissionDenied});

  final bool permissionDenied;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                permissionDenied ? Icons.no_photography : Icons.videocam_off,
                color: Colors.white,
                size: 48,
              ),
              const SizedBox(height: 12),
              Text(
                permissionDenied
                    ? 'Izin kamera ditolak'
                    : 'Kamera tidak bisa dibuka',
                style: theme.textTheme.titleMedium
                    ?.copyWith(color: Colors.white),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                permissionDenied
                    ? 'Aktifkan izin Kamera untuk aplikasi ini, lalu kembali '
                        'ke halaman scan. Input manual tetap bisa dipakai.'
                    : 'Tutup aplikasi lain yang memakai kamera, atau pakai '
                        'input manual.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () {
                  unawaited(
                    AppSettings.openAppSettings(
                      type: AppSettingsType.settings,
                    ),
                  );
                },
                icon: const Icon(Icons.settings_outlined),
                label: const Text('Buka setelan'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
