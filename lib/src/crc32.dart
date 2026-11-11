import 'dart:typed_data';

/// IEEE 802.3 CRC-32 checksum utility and compact byte codecs for `.pak` payloads.
final class Crc32 {
  static final Uint32List _table = _buildTable();

  static Uint32List _buildTable() {
    final t = Uint32List(256);
    for (int i = 0; i < 256; i++) {
      var c = i;
      for (int j = 0; j < 8; j++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      t[i] = c;
    }
    return t;
  }

  static int compute(Uint8List bytes, [int start = 0, int? end]) {
    final limit = end ?? bytes.length;
    var crc = 0xFFFFFFFF;
    for (int i = start; i < limit; i++) {
      crc = _table[(crc ^ bytes[i]) & 0xFF] ^ (crc >>> 8);
    }
    return (crc ^ 0xFFFFFFFF) >>> 0;
  }
}

/// Fast lossless PackBits-style RLE compression and seeded XOR obfuscation.
final class PackCodec {
  /// Compresses [input] using literal / repeat control packets (`1..128` bytes).
  static Uint8List encodeRle(Uint8List input) {
    if (input.isEmpty) return Uint8List(0);
    final out = BytesBuilder(copy: false);
    var i = 0;
    final n = input.length;

    while (i < n) {
      // Check for run of identical bytes (at least 3)
      var run = 1;
      while (i + run < n && run < 128 && input[i + run] == input[i]) {
        run++;
      }
      if (run >= 3) {
        out.addByte(0x80 | (run - 1));
        out.addByte(input[i]);
        i += run;
      } else {
        final litStart = i;
        var litLen = 0;
        while (i + litLen < n && litLen < 128) {
          final cur = input[i + litLen];
          var lookRun = 1;
          while (i + litLen + lookRun < n &&
              lookRun < 3 &&
              input[i + litLen + lookRun] == cur) {
            lookRun++;
          }
          if (lookRun >= 3 && litLen > 0) break;
          litLen++;
        }
        out.addByte(litLen - 1);
        for (int k = 0; k < litLen; k++) {
          out.addByte(input[litStart + k]);
        }
        i += litLen;
      }
    }
    return out.toBytes();
  }

  /// Decompresses PackBits-style RLE stream into exact [expectedLength] bytes.
  static Uint8List decodeRle(Uint8List encoded, {int? expectedLength}) {
    if (encoded.isEmpty) return Uint8List(0);
    final out = BytesBuilder(copy: false);
    var i = 0;
    while (i < encoded.length) {
      final header = encoded[i++];
      if ((header & 0x80) != 0) {
        final count = (header & 0x7F) + 1;
        if (i >= encoded.length) {
          throw const FormatException('Truncated RLE repeat token.');
        }
        final val = encoded[i++];
        for (int k = 0; k < count; k++) {
          out.addByte(val);
        }
      } else {
        final count = header + 1;
        if (i + count > encoded.length) {
          throw const FormatException('Truncated RLE literal run.');
        }
        out.add(Uint8List.sublistView(encoded, i, i + count));
        i += count;
      }
    }
    final result = out.toBytes();
    if (expectedLength != null && result.length != expectedLength) {
      throw FormatException(
        'RLE decoded length ${result.length} != expected $expectedLength.',
      );
    }
    return result;
  }

  /// Applies a deterministic keystream mask using SplitMix-style state.
  static Uint8List xorMask(Uint8List input, int seedKey) {
    final result = Uint8List.fromList(input);
    var state = (seedKey ^ 0x9E3779B9) & 0xFFFFFFFF;
    for (int i = 0; i < result.length; i++) {
      state = (state * 1664525 + 1013904223) & 0xFFFFFFFF;
      result[i] ^= (state >>> 16) & 0xFF;
    }
    return result;
  }
}
