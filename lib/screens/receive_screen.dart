import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_sender/screens/video_screen.dart';
import 'package:qr_sender/transfer/transfer_protocol.dart';

class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key});

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  final _receiver = TransferReceiver();
  final _scanner = MobileScannerController(
    detectionSpeed: DetectionSpeed.unrestricted,
  );
  bool _saving = false;

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_saving) return;
    var changed = false;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;
      try {
        changed = _receiver.add(value) || changed;
      } on FormatException {
        // Ignore unrelated or damaged QR codes while the camera keeps scanning.
      }
    }
    if (changed && mounted) setState(() {});
    if (_receiver.isComplete && !_saving) await _saveAndOpen();
  }

  Future<void> _saveAndOpen() async {
    await _writeAndOpen(isPartial: false);
  }

  Future<void> _openPreview() async {
    await _writeAndOpen(isPartial: true);
  }

  Future<void> _writeAndOpen({required bool isPartial}) async {
    _saving = true;
    await _scanner.stop();
    try {
      final directory = await getApplicationDocumentsDirectory();
      final name = _receiver.fileName ?? 'received_video.mp4';
      final path =
          '${directory.path}${Platform.pathSeparator}${isPartial ? 'preview' : 'received'}_${DateTime.now().millisecondsSinceEpoch}_$name';
      final file = await File(path).writeAsBytes(
        isPartial ? _receiver.buildPreview() : _receiver.build(),
        flush: true,
      );
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => VideoScreen(file: file, isPartial: isPartial),
        ),
      );
    } catch (error) {
      _saving = false;
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذر حفظ الفيديو: $error')));
        await _scanner.start();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final percent = (_receiver.progress * 100).round();
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('استقبال فيديو')),
        body: Stack(
          fit: StackFit.expand,
          children: [
            MobileScanner(controller: _scanner, onDetect: _onDetect),
            Center(
              child: Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 3),
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                child: Container(
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LinearProgressIndicator(
                        value: _receiver.totalCount == 0
                            ? null
                            : _receiver.progress,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _receiver.totalCount == 0
                            ? 'التقط الqr'
                            : 'تم استقبال ${_receiver.receivedCount} من ${_receiver.totalCount} ($percent٪)',
                        style: const TextStyle(color: Colors.white),
                        textAlign: TextAlign.center,
                      ),
                      if (_receiver.totalCount > 0 &&
                          !_receiver.canPreview) ...[
                        const SizedBox(height: 6),
                        const Text(
                          '',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      if (_receiver.canPreview && !_receiver.isComplete) ...[
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _saving ? null : _openPreview,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('عرض المتوفر الآن'),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
