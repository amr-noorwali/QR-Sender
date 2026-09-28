import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:qr_sender/transfer/transfer_protocol.dart';

class SendScreen extends StatefulWidget {
  const SendScreen({super.key});

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  static const _maxBytes = 10 * 1024 * 1024;
  List<String>? _frames;
  TransferEncoder? _encoder;
  String? _currentFrame;
  int _current = 0;
  int _repairSeed = 0;
  String? _fileName;
  bool _loading = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _pickVideo() async {
    setState(() => _loading = true);
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.video);
      if (result == null || !mounted) return;
      final picked = result.files.single;
      if (picked.path == null) throw Exception('تعذر الوصول إلى الملف');
      if (picked.size > _maxBytes) {
        throw Exception('اختر فيديو حجمه 10 MB أو أقل ');
      }
      final bytes = await File(picked.path!).readAsBytes();
      final encoder = TransferEncoder(
        bytes: bytes,
        fileName: picked.name,
        sessionId:
            '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}',
      );
      final frames = encoder.originalFrames;
      _timer?.cancel();
      if (!mounted) return;
      setState(() {
        _frames = frames;
        _encoder = encoder;
        _currentFrame = frames.first;
        _fileName = picked.name;
        _current = 0;
        _repairSeed = 0;
      });
      _timer = Timer.periodic(const Duration(milliseconds: 300), (_) {
        if (mounted && _frames != null) {
          setState(() {
            if (_current + 1 < _frames!.length) {
              _current++;
              _currentFrame = _frames![_current];
            } else {
              _repairSeed++;
              _currentFrame = _encoder!.repairFrame(_repairSeed);
            }
          });
        }
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.toString().replaceFirst('Exception: ', '')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final frames = _frames;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('إرسال فيديو')),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: frames == null
              ? Center(
                  child: FilledButton.icon(
                    onPressed: _loading ? null : _pickVideo,
                    icon: const Icon(Icons.video_library_outlined),
                    label: Text(
                      _loading
                          ? 'جارٍ تجهيز الفيديو'
                          : 'اختيار فيديو (حتى 10 MB)',
                    ),
                  ),
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _fileName!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: QrImageView(
                            data: _currentFrame!,
                            version: QrVersions.auto,
                            errorCorrectionLevel: QrErrorCorrectLevel.L,
                            padding: const EdgeInsets.all(8),
                            backgroundColor: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    Text(
                      _repairSeed == 0
                          ? 'الجزء الأصلي ${_current + 1} من ${frames.length}'
                          : 'qr تعويضي جديد رقم $_repairSeed',
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _repairSeed == 0
                          ? 'بدا ارسال الqr التعويضية'
                          : '',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _pickVideo,
                      child: const Text('اختيار فيديو آخر'),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
