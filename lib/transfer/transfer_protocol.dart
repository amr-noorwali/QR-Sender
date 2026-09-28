import 'dart:convert';
import 'dart:typed_data';

class TransferProtocol {
  static const int version = 2;
  static const int defaultChunkSize = 700;

  static List<String> encode({
    required Uint8List bytes,
    required String fileName,
    required String sessionId,
    int chunkSize = defaultChunkSize,
  }) => TransferEncoder(
    bytes: bytes,
    fileName: fileName,
    sessionId: sessionId,
    chunkSize: chunkSize,
  ).originalFrames;

  static BigInt repairMask(int total, int seed) {
    var mask = BigInt.zero;
    for (var index = 0; index < total; index++) {
      var value = (seed ^ (index * 0x9e3779b9)) & 0xffffffff;
      value = ((value ^ (value >> 16)) * 0x7feb352d) & 0xffffffff;
      value = ((value ^ (value >> 15)) * 0x846ca68b) & 0xffffffff;
      value = (value ^ (value >> 16)) & 0xffffffff;
      if (value.isOdd) mask |= BigInt.one << index;
    }
    if (mask == BigInt.zero) mask = BigInt.one << (seed.abs() % total);
    return mask;
  }

  static int crc32(List<int> bytes) {
    var crc = 0xffffffff;
    for (final byte in bytes) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
      }
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }
}

class TransferEncoder {
  TransferEncoder({
    required this.bytes,
    required String fileName,
    required this.sessionId,
    this.chunkSize = TransferProtocol.defaultChunkSize,
  }) : fileName = _safeName(fileName) {
    if (bytes.isEmpty) throw ArgumentError('The file is empty.');
    if (chunkSize <= 0) throw ArgumentError.value(chunkSize, 'chunkSize');
    _chunks = List<Uint8List>.generate(totalCount, (index) {
      final start = index * chunkSize;
      final end = (start + chunkSize).clamp(0, bytes.length);
      return Uint8List.sublistView(bytes, start, end);
    });
  }

  final Uint8List bytes;
  final String fileName;
  final String sessionId;
  final int chunkSize;
  late final List<Uint8List> _chunks;

  int get totalCount => (bytes.length / chunkSize).ceil();
  int get fileChecksum => TransferProtocol.crc32(bytes);

  late final List<String> originalFrames = List<String>.generate(
    totalCount,
    (index) => _frame(type: 'd', value: index, data: _chunks[index]),
  );

  String repairFrame(int seed) {
    final mask = TransferProtocol.repairMask(totalCount, seed);
    final data = Uint8List(chunkSize);
    for (var index = 0; index < totalCount; index++) {
      if (!_hasBit(mask, index)) continue;
      _xorInto(data, _chunks[index]);
    }
    return _frame(type: 'r', value: seed, data: data);
  }

  String _frame({
    required String type,
    required int value,
    required Uint8List data,
  }) => jsonEncode({
    'v': TransferProtocol.version,
    't': type,
    's': sessionId,
    if (type == 'd') 'i': value else 'e': value,
    'n': totalCount,
    'f': fileName,
    'z': bytes.length,
    'q': chunkSize,
    'h': fileChecksum,
    'c': TransferProtocol.crc32(data),
    'd': base64Encode(data),
  });

  static String _safeName(String value) {
    final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return safe.isEmpty ? 'video.mp4' : safe;
  }
}

class TransferReceiver {
  String? _sessionId;
  String? _fileName;
  int? _totalCount;
  int? _fileSize;
  int? _chunkSize;
  int? _fileChecksum;
  final Map<int, Uint8List> _chunks = {};
  final Map<int, _Equation> _equations = {};

  String? get fileName => _fileName;
  int get receivedCount {
    final information = _chunks.length + _equations.length;
    return information > totalCount ? totalCount : information;
  }

  int get totalCount => _totalCount ?? 0;
  bool get isComplete => _totalCount != null && _chunks.length == _totalCount;
  double get progress => totalCount == 0 ? 0 : receivedCount / totalCount;
  int get contiguousReceivedCount {
    var count = 0;
    while (_chunks.containsKey(count)) {
      count++;
    }
    return count;
  }

  bool get canPreview =>
      totalCount > 0 && contiguousReceivedCount * 2 >= totalCount;

  bool add(String encodedFrame) {
    final Map<String, dynamic> raw;
    try {
      final decoded = jsonDecode(encodedFrame);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      raw = decoded;
    } catch (_) {
      throw const FormatException('Not a QR Video frame.');
    }
    if (raw['v'] != TransferProtocol.version) {
      throw const FormatException('Unsupported frame.');
    }

    final type = raw['t'];
    final session = raw['s'];
    final total = raw['n'];
    final name = raw['f'];
    final size = raw['z'];
    final chunkSize = raw['q'];
    final fileChecksum = raw['h'];
    final chunkChecksum = raw['c'];
    final encodedData = raw['d'];
    if ((type != 'd' && type != 'r') ||
        session is! String ||
        total is! int ||
        total <= 0 ||
        name is! String ||
        size is! int ||
        chunkSize is! int ||
        chunkSize <= 0 ||
        fileChecksum is! int ||
        chunkChecksum is! int ||
        encodedData is! String) {
      throw const FormatException('Malformed frame.');
    }
    _validateMetadata(session, total, size, chunkSize, fileChecksum);

    final Uint8List data;
    try {
      data = base64Decode(encodedData);
    } catch (_) {
      throw const FormatException('Invalid frame data.');
    }
    if (TransferProtocol.crc32(data) != chunkChecksum) {
      throw const FormatException('Corrupted frame.');
    }

    _sessionId ??= session;
    _fileName ??= name;
    _totalCount ??= total;
    _fileSize ??= size;
    _chunkSize ??= chunkSize;
    _fileChecksum ??= fileChecksum;

    if (type == 'd') return _addOriginal(raw['i'], data);
    return _addRepair(raw['e'], data);
  }

  void _validateMetadata(
    String session,
    int total,
    int size,
    int chunkSize,
    int checksum,
  ) {
    if (_sessionId != null && _sessionId != session) {
      throw const FormatException('Frame belongs to another transfer.');
    }
    if (_totalCount != null &&
        (_totalCount != total ||
            _fileSize != size ||
            _chunkSize != chunkSize ||
            _fileChecksum != checksum)) {
      throw const FormatException('Transfer metadata changed.');
    }
  }

  bool _addOriginal(Object? rawIndex, Uint8List data) {
    if (rawIndex is! int || rawIndex < 0 || rawIndex >= totalCount) {
      throw const FormatException('Malformed original frame.');
    }
    final expectedLength = rawIndex == totalCount - 1
        ? _fileSize! - rawIndex * _chunkSize!
        : _chunkSize!;
    if (data.length != expectedLength) {
      throw const FormatException('Original frame has the wrong size.');
    }
    if (_chunks.containsKey(rawIndex)) return false;
    _chunks[rawIndex] = data;
    _rebuildEquations();
    return true;
  }

  bool _addRepair(Object? rawSeed, Uint8List data) {
    if (rawSeed is! int || data.length != _chunkSize) {
      throw const FormatException('Malformed repair frame.');
    }
    final equation = _Equation(
      TransferProtocol.repairMask(totalCount, rawSeed),
      Uint8List.fromList(data),
    );
    final added = _insertEquation(equation);
    if (added) _tryDecodeAll();
    return added;
  }

  void _rebuildEquations() {
    if (_equations.isEmpty) return;
    final existing = _equations.values.toList();
    _equations.clear();
    for (final equation in existing) {
      _insertEquation(equation);
    }
    _tryDecodeAll();
  }

  bool _insertEquation(_Equation source) {
    var mask = source.mask;
    final data = Uint8List.fromList(source.data);
    for (final entry in _chunks.entries) {
      if (_hasBit(mask, entry.key)) {
        mask &= ~(BigInt.one << entry.key);
        _xorInto(data, entry.value);
      }
    }
    while (mask != BigInt.zero) {
      final pivot = _lowestBit(mask);
      final existing = _equations[pivot];
      if (existing == null) {
        _equations[pivot] = _Equation(mask, data);
        return true;
      }
      mask ^= existing.mask;
      _xorInto(data, existing.data);
    }
    return false;
  }

  void _tryDecodeAll() {
    final unknownCount = totalCount - _chunks.length;
    if (unknownCount == 0 || _equations.length < unknownCount) return;
    final solved = <int, Uint8List>{};
    final pivots = _equations.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final pivot in pivots) {
      final equation = _equations[pivot]!;
      final data = Uint8List.fromList(equation.data);
      for (final entry in solved.entries) {
        if (_hasBit(equation.mask, entry.key)) _xorInto(data, entry.value);
      }
      solved[pivot] = data;
    }
    if (solved.length != unknownCount) return;
    for (final entry in solved.entries) {
      final expectedLength = entry.key == totalCount - 1
          ? _fileSize! - entry.key * _chunkSize!
          : _chunkSize!;
      _chunks[entry.key] = Uint8List.sublistView(
        entry.value,
        0,
        expectedLength,
      );
    }
    _equations.clear();
  }

  Uint8List build() {
    if (!isComplete) throw StateError('Transfer is incomplete.');
    final builder = BytesBuilder(copy: false);
    for (var index = 0; index < totalCount; index++) {
      builder.add(_chunks[index]!);
    }
    final bytes = builder.takeBytes();
    if (bytes.length != _fileSize ||
        TransferProtocol.crc32(bytes) != _fileChecksum) {
      throw const FormatException('Completed file failed verification.');
    }
    return bytes;
  }

  Uint8List buildPreview() {
    if (!canPreview) {
      throw StateError(
        'The first contiguous 50 percent is required for a preview.',
      );
    }
    final builder = BytesBuilder(copy: false);
    for (var index = 0; index < contiguousReceivedCount; index++) {
      builder.add(_chunks[index]!);
    }
    return builder.takeBytes();
  }
}

class _Equation {
  const _Equation(this.mask, this.data);
  final BigInt mask;
  final Uint8List data;
}

bool _hasBit(BigInt mask, int index) =>
    (mask & (BigInt.one << index)) != BigInt.zero;

int _lowestBit(BigInt value) {
  var index = 0;
  while (!value.isOdd) {
    value >>= 1;
    index++;
  }
  return index;
}

void _xorInto(Uint8List target, List<int> source) {
  for (var index = 0; index < source.length; index++) {
    target[index] ^= source[index];
  }
}
