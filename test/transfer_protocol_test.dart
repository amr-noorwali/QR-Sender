import 'dart:convert';
import 'dart:typed_data';

import 'package:qr_sender/transfer/transfer_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('TransferProtocol', () {
    test('splits and rebuilds bytes without changing them', () {
      final bytes = Uint8List.fromList(
        List<int>.generate(4097, (i) => i % 251),
      );

      final frames = TransferProtocol.encode(
        bytes: bytes,
        fileName: 'clip.mp4',
        sessionId: 'session-a',
        chunkSize: 700,
      );
      final receiver = TransferReceiver();
      for (final frame in frames.reversed) {
        receiver.add(frame);
      }

      expect(receiver.isComplete, isTrue);
      expect(receiver.fileName, 'clip.mp4');
      expect(receiver.progress, 1);
      expect(receiver.build(), bytes);
    });

    test('ignores duplicate frames', () {
      final frames = TransferProtocol.encode(
        bytes: Uint8List.fromList(utf8.encode('a small video payload')),
        fileName: 'tiny.mp4',
        sessionId: 'session-b',
        chunkSize: 5,
      );
      final receiver = TransferReceiver();

      receiver.add(frames.first);
      receiver.add(frames.first);

      expect(receiver.receivedCount, 1);
      expect(receiver.totalCount, frames.length);
    });

    test('rejects a corrupted frame', () {
      final frame = TransferProtocol.encode(
        bytes: Uint8List.fromList([1, 2, 3, 4]),
        fileName: 'clip.mp4',
        sessionId: 'session-c',
        chunkSize: 700,
      ).single;
      final decoded = jsonDecode(frame) as Map<String, dynamic>;
      decoded['d'] = base64Encode([9, 9, 9]);

      expect(
        () => TransferReceiver().add(jsonEncode(decoded)),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects frames from another transfer', () {
      final first = TransferProtocol.encode(
        bytes: Uint8List.fromList([1, 2]),
        fileName: 'one.mp4',
        sessionId: 'one',
        chunkSize: 1,
      );
      final second = TransferProtocol.encode(
        bytes: Uint8List.fromList([3, 4]),
        fileName: 'two.mp4',
        sessionId: 'two',
        chunkSize: 1,
      );
      final receiver = TransferReceiver()..add(first.first);

      expect(() => receiver.add(second.first), throwsA(isA<FormatException>()));
    });

    test('builds a preview from the first contiguous 50 percent', () {
      final bytes = Uint8List.fromList(List<int>.generate(8, (i) => i + 1));
      final frames = TransferProtocol.encode(
        bytes: bytes,
        fileName: 'preview.mp4',
        sessionId: 'preview',
        chunkSize: 2,
      );
      final receiver = TransferReceiver()
        ..add(frames[0])
        ..add(frames[1]);

      expect(receiver.canPreview, isTrue);
      expect(receiver.buildPreview(), [1, 2, 3, 4]);
    });

    test('does not preview when 50 percent contains an early gap', () {
      final frames = TransferProtocol.encode(
        bytes: Uint8List.fromList(List<int>.generate(8, (i) => i)),
        fileName: 'gapped.mp4',
        sessionId: 'preview-gapped',
        chunkSize: 2,
      );
      final receiver = TransferReceiver()
        ..add(frames[0])
        ..add(frames[2]);

      expect(receiver.canPreview, isFalse);
      expect(receiver.buildPreview, throwsStateError);
    });

    test('recovers missing chunks from one-way repair frames', () {
      final bytes = Uint8List.fromList(
        List<int>.generate(800, (i) => (i * 17) % 256),
      );
      final encoder = TransferEncoder(
        bytes: bytes,
        fileName: 'lossy.mp4',
        sessionId: 'fountain-session',
        chunkSize: 20,
      );
      final receiver = TransferReceiver();

      for (var index = 0; index < encoder.totalCount; index += 2) {
        receiver.add(encoder.originalFrames[index]);
      }
      for (var seed = 1; seed <= 80 && !receiver.isComplete; seed++) {
        receiver.add(encoder.repairFrame(seed));
      }

      expect(receiver.isComplete, isTrue);
      expect(receiver.build(), bytes);
    });

    test('generates a different repair frame for every seed', () {
      final encoder = TransferEncoder(
        bytes: Uint8List.fromList(List<int>.generate(100, (i) => i)),
        fileName: 'clip.mp4',
        sessionId: 'unique-repairs',
        chunkSize: 10,
      );

      expect(encoder.repairFrame(1), isNot(encoder.repairFrame(2)));
    });

    test('reconstructs a 500-chunk transfer after losing 40 percent', () {
      final bytes = Uint8List.fromList(
        List<int>.generate(5000, (i) => (i * 31) % 256),
      );
      final encoder = TransferEncoder(
        bytes: bytes,
        fileName: 'large-loss.mp4',
        sessionId: 'large-loss',
        chunkSize: 10,
      );
      final receiver = TransferReceiver();

      for (var index = 0; index < encoder.totalCount; index++) {
        if (index % 5 < 3) receiver.add(encoder.originalFrames[index]);
      }
      for (var seed = 1; seed <= 300 && !receiver.isComplete; seed++) {
        receiver.add(encoder.repairFrame(seed));
      }

      expect(receiver.isComplete, isTrue);
      expect(receiver.build(), bytes);
    });
  });
}
