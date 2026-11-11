import 'dart:convert';
import 'dart:typed_data';

import 'crc32.dart';
import 'vfs.dart';

/// Metadata entry describing a stored asset inside a [PakArchive].
final class PakEntryInfo {
  final String path;
  final int dataOffset;
  final int storedSize;
  final int rawSize;
  final int flags;
  final int crc32;

  const PakEntryInfo({
    required this.path,
    required this.dataOffset,
    required this.storedSize,
    required this.rawSize,
    required this.flags,
    required this.crc32,
  });

  bool get isCompressed => (flags & 0x01) != 0;
  bool get isMasked => (flags & 0x02) != 0;
}

final class _PendingEntry {
  final String path;
  final Uint8List storedBytes;
  final int rawSize;
  final int flags;
  final int crc32;

  const _PendingEntry({
    required this.path,
    required this.storedBytes,
    required this.rawSize,
    required this.flags,
    required this.crc32,
  });
}

/// Writes an indexed, CRC32-verified binary `.pak` asset bundle.
final class PakBuilder {
  static const int magic = 0x5650414B; // 'VPAK'
  static const int formatVersion = 1;
  static const int _headerSize = 16;

  final List<_PendingEntry> _pending = [];

  void addBytes(
    String virtualPath,
    Uint8List rawBytes, {
    bool compress = true,
    int? xorKey,
  }) {
    final normPath = VfsPath.normalize(virtualPath);
    if (normPath.isEmpty) {
      throw ArgumentError.value(virtualPath, 'virtualPath', 'must not be empty');
    }

    final rawCrc = Crc32.compute(rawBytes);
    var flags = 0;
    var payload = rawBytes;

    if (compress && rawBytes.length > 8) {
      final compressed = PackCodec.encodeRle(rawBytes);
      if (compressed.length < rawBytes.length) {
        payload = compressed;
        flags |= 0x01;
      }
    }

    if (xorKey != null) {
      payload = PackCodec.xorMask(payload, xorKey);
      flags |= 0x02;
    }

    _pending.removeWhere((e) => e.path == normPath);
    _pending.add(_PendingEntry(
      path: normPath,
      storedBytes: payload,
      rawSize: rawBytes.length,
      flags: flags,
      crc32: rawCrc,
    ));
  }

  void addText(
    String virtualPath,
    String text, {
    bool compress = true,
    int? xorKey,
  }) {
    addBytes(
      virtualPath,
      Uint8List.fromList(utf8.encode(text)),
      compress: compress,
      xorKey: xorKey,
    );
  }

  Uint8List build() {
    var payloadLength = 0;
    for (final e in _pending) {
      payloadLength += e.storedBytes.length;
    }

    final tocOffset = _headerSize + payloadLength;
    final tocBuilder = BytesBuilder(copy: false);
    var cursorOffset = _headerSize;

    for (final e in _pending) {
      final pathBytes = utf8.encode(e.path);
      final meta = ByteData(2 + 4 * 5);
      meta.setUint16(0, pathBytes.length, Endian.little);
      meta.setUint32(2, cursorOffset, Endian.little);
      meta.setUint32(6, e.storedBytes.length, Endian.little);
      meta.setUint32(10, e.rawSize, Endian.little);
      meta.setUint32(14, e.flags, Endian.little);
      meta.setUint32(18, e.crc32, Endian.little);
      tocBuilder.add(meta.buffer.asUint8List());
      tocBuilder.add(pathBytes);
      cursorOffset += e.storedBytes.length;
    }

    final tocBytes = tocBuilder.toBytes();
    final tocCrc = Crc32.compute(tocBytes);

    final totalSize = _headerSize + payloadLength + tocBytes.length;
    final out = Uint8List(totalSize);
    final header = ByteData.sublistView(out, 0, _headerSize);
    header.setUint32(0, magic, Endian.big);
    header.setUint16(4, formatVersion, Endian.little);
    header.setUint16(6, 0, Endian.little);
    header.setUint32(8, _pending.length, Endian.little);
    header.setUint32(12, tocOffset, Endian.little);

    // Put 4-byte TOC CRC right at end of TOC stream so payload doesn't move? Wait:
    // Better: allocate +4 bytes footer for tocCrc at very end of archive.
    final fullOut = Uint8List(totalSize + 4);
    fullOut.setRange(0, _headerSize, out);

    var writePos = _headerSize;
    for (final e in _pending) {
      fullOut.setRange(writePos, writePos + e.storedBytes.length, e.storedBytes);
      writePos += e.storedBytes.length;
    }
    fullOut.setRange(tocOffset, tocOffset + tocBytes.length, tocBytes);
    final footer = ByteData.sublistView(fullOut, tocOffset + tocBytes.length, fullOut.length);
    footer.setUint32(0, tocCrc, Endian.little);

    return fullOut;
  }
}

/// Random-access reader over an in-memory binary `.pak` buffer.
final class PakArchive {
  final Uint8List _bytes;
  final int? xorKey;
  final Map<String, PakEntryInfo> _entries;

  PakArchive._(this._bytes, this.xorKey, this._entries);

  Iterable<PakEntryInfo> get entries => _entries.values;
  int get length => _entries.length;
  bool contains(String path) => _entries.containsKey(VfsPath.normalize(path));
  PakEntryInfo? infoFor(String path) => _entries[VfsPath.normalize(path)];

  factory PakArchive.parse(
    Uint8List bytes, {
    int? xorKey,
    bool verifyTocChecksum = true,
  }) {
    if (bytes.length < PakBuilder._headerSize + 4) {
      throw const FormatException('Archive truncated before header.');
    }
    final header = ByteData.sublistView(bytes, 0, PakBuilder._headerSize);
    final magic = header.getUint32(0, Endian.big);
    if (magic != PakBuilder.magic) {
      throw FormatException('Invalid VPAK magic header: 0x${magic.toRadixString(16)}');
    }
    final version = header.getUint16(4, Endian.little);
    if (version != PakBuilder.formatVersion) {
      throw FormatException('Unsupported VPAK version: $version');
    }
    final entryCount = header.getUint32(8, Endian.little);
    final tocOffset = header.getUint32(12, Endian.little);
    if (tocOffset < PakBuilder._headerSize || tocOffset > bytes.length - 4) {
      throw const FormatException('Invalid VPAK TOC offset.');
    }

    final tocEnd = bytes.length - 4;
    if (verifyTocChecksum) {
      final expectedCrc = ByteData.sublistView(bytes, tocEnd, bytes.length).getUint32(0, Endian.little);
      final actualCrc = Crc32.compute(bytes, tocOffset, tocEnd);
      if (actualCrc != expectedCrc) {
        throw const FormatException('VPAK table-of-contents CRC32 mismatch.');
      }
    }

    final entries = <String, PakEntryInfo>{};
    var pos = tocOffset;
    const fixedMetaSize = 2 + 4 * 5;

    for (int i = 0; i < entryCount; i++) {
      if (pos + fixedMetaSize > tocEnd) {
        throw const FormatException('Truncated VPAK TOC entry metadata.');
      }
      final meta = ByteData.sublistView(bytes, pos, pos + fixedMetaSize);
      final pathLen = meta.getUint16(0, Endian.little);
      final dataOffset = meta.getUint32(2, Endian.little);
      final storedSize = meta.getUint32(6, Endian.little);
      final rawSize = meta.getUint32(10, Endian.little);
      final flags = meta.getUint32(14, Endian.little);
      final crc = meta.getUint32(18, Endian.little);
      pos += fixedMetaSize;

      if (pos + pathLen > tocEnd) {
        throw const FormatException('Truncated VPAK TOC entry path.');
      }
      final entryPath = utf8.decode(Uint8List.sublistView(bytes, pos, pos + pathLen));
      pos += pathLen;

      if (dataOffset < PakBuilder._headerSize || dataOffset + storedSize > tocOffset) {
        throw FormatException('Out-of-bounds entry slice for "$entryPath".');
      }

      entries[entryPath] = PakEntryInfo(
        path: entryPath,
        dataOffset: dataOffset,
        storedSize: storedSize,
        rawSize: rawSize,
        flags: flags,
        crc32: crc,
      );
    }

    return PakArchive._(bytes, xorKey, entries);
  }

  Uint8List? readBytes(String virtualPath, {bool verifyChecksum = true}) {
    final info = infoFor(virtualPath);
    if (info == null) return null;

    var data = Uint8List.fromList(
      Uint8List.sublistView(_bytes, info.dataOffset, info.dataOffset + info.storedSize),
    );
    if (info.isMasked) {
      if (xorKey == null) {
        throw StateError('Asset "${info.path}" is masked and requires xorKey.');
      }
      data = PackCodec.xorMask(data, xorKey!);
    }
    if (info.isCompressed) {
      data = PackCodec.decodeRle(data, expectedLength: info.rawSize);
    }
    if (verifyChecksum) {
      final actualCrc = Crc32.compute(data);
      if (actualCrc != info.crc32) {
        throw FormatException('CRC32 verification failed for "${info.path}".');
      }
    }
    return data;
  }

  String? readText(String virtualPath, {bool verifyChecksum = true}) {
    final bytes = readBytes(virtualPath, verifyChecksum: verifyChecksum);
    return bytes == null ? null : utf8.decode(bytes);
  }
}
