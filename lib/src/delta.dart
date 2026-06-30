import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Binary delta between a base file and a target file, as a stream of
/// COPY(from base) / INSERT(literal) ops. Used to shrink patch downloads:
/// pack ships the delta against the release `libapp.so`, the device reconstructs
/// the new `libapp.so` from its installed base, then verifies the result's
/// SHA-256. The op semantics are dead simple, so the device applier is trivial
/// and safe; all the cleverness (and any bug) lives in [buildDelta], which
/// **self-verifies** before returning.
///
/// Format (little-endian, LEB128 unsigned varints):
///   magic "FPD1"
///   repeated ops until EOF:
///     0x00 COPY:   varint baseOffset, varint length
///     0x01 INSERT: varint length, length literal bytes
class DeltaCodec {
  DeltaCodec._();

  static const List<int> magic = [0x46, 0x50, 0x44, 0x31]; // "FPD1"
  static const int _opCopy = 0x00;
  static const int _opInsert = 0x01;
  static const int _blockSize = 2048;
  static const int _adlerMod = 65521;

  /// Builds a delta turning [base] into [target]. Self-verifies (reconstructs and
  /// checks it equals [target]) before returning; throws [StateError] on a bug.
  static Uint8List buildDelta(Uint8List base, Uint8List target) {
    final out = _ByteWriter()..addBytes(magic);

    // Index non-overlapping base blocks: weakHash -> { strongHex -> baseOffset }.
    final index = <int, Map<String, int>>{};
    for (var off = 0; off + _blockSize <= base.length; off += _blockSize) {
      final weak = _weakHash(base, off, _blockSize);
      final strong = _strongHex(base, off, _blockSize);
      (index[weak] ??= <String, int>{})[strong] = off;
    }

    var litStart = 0;
    var pos = 0;
    // Pending COPY run we can extend if the next match is base-contiguous.
    var copyBaseOff = -1;
    var copyLen = 0;

    void flushCopy() {
      if (copyLen > 0) {
        out.addByte(_opCopy);
        out.addVarint(copyBaseOff);
        out.addVarint(copyLen);
        copyBaseOff = -1;
        copyLen = 0;
      }
    }

    void flushLiteral(int end) {
      if (end > litStart) {
        out.addByte(_opInsert);
        out.addVarint(end - litStart);
        out.addBytes(Uint8List.sublistView(target, litStart, end));
      }
      litStart = end;
    }

    int? rolling;
    while (pos + _blockSize <= target.length) {
      rolling ??= _weakHash(target, pos, _blockSize);
      final candidates = index[rolling];
      int? matchOff;
      if (candidates != null) {
        final strong = _strongHex(target, pos, _blockSize);
        matchOff = candidates[strong];
      }
      if (matchOff != null) {
        flushLiteral(pos); // literal bytes before this match
        if (copyLen > 0 && matchOff == copyBaseOff + copyLen) {
          copyLen += _blockSize; // extend a contiguous COPY run
        } else {
          flushCopy();
          copyBaseOff = matchOff;
          copyLen = _blockSize;
        }
        pos += _blockSize;
        litStart = pos;
        rolling = null; // recompute window at the new position
      } else {
        flushCopy();
        // Slide one byte. Roll only when a full next window exists (the roll reads
        // target[pos + blockSize]); at the last window, drop to recompute/exit.
        if (pos + _blockSize < target.length) {
          rolling = _rollHash(rolling, target, pos, _blockSize);
        } else {
          rolling = null;
        }
        pos += 1;
      }
    }
    flushCopy();
    flushLiteral(target.length); // trailing literal (incl. < blockSize tail)

    final delta = out.toBytes();
    // Self-check: a delta that doesn't reconstruct the target is a bug — fail loud.
    final rebuilt = applyDelta(base, delta);
    if (!_bytesEqual(rebuilt, target)) {
      throw StateError('delta self-check failed (reconstruction != target)');
    }
    return delta;
  }

  /// Applies a delta to [base], returning the reconstructed bytes.
  static Uint8List applyDelta(Uint8List base, Uint8List delta) {
    var i = 0;
    for (final b in magic) {
      if (i >= delta.length || delta[i] != b) {
        throw const FormatException('bad delta magic');
      }
      i++;
    }
    final out = _ByteWriter();
    while (i < delta.length) {
      final op = delta[i++];
      if (op == _opCopy) {
        final res1 = _readVarint(delta, i);
        final baseOff = res1.value;
        i = res1.next;
        final res2 = _readVarint(delta, i);
        final len = res2.value;
        i = res2.next;
        // Overflow-safe bounds: subtract instead of `baseOff + len` so a hostile
        // varint can't wrap past the array length.
        if (baseOff < 0 || len < 0 || baseOff > base.length - len) {
          throw FormatException('COPY out of range: off=$baseOff len=$len base=${base.length}');
        }
        out.addBytes(Uint8List.sublistView(base, baseOff, baseOff + len));
      } else if (op == _opInsert) {
        final res = _readVarint(delta, i);
        final len = res.value;
        i = res.next;
        if (len < 0 || len > delta.length - i) {
          throw FormatException('INSERT out of range: len=$len');
        }
        out.addBytes(Uint8List.sublistView(delta, i, i + len));
        i += len;
      } else {
        throw FormatException('bad delta op $op');
      }
    }
    return out.toBytes();
  }

  // Canonical rsync rolling checksum (a,b start at 0):
  //   a = Σ byte_j ; b = Σ (len-j)·byte_j   (both mod _adlerMod)
  static int _weakHash(Uint8List data, int off, int len) {
    var a = 0;
    var b = 0;
    for (var k = 0; k < len; k++) {
      a = (a + data[off + k]) % _adlerMod;
      b = (b + a) % _adlerMod;
    }
    return (b << 16) | a;
  }

  // Roll [pos, pos+len) one byte forward to [pos+1, pos+1+len).
  //   a' = a - X_out + X_in ; b' = b - len·X_out + a'   (mod _adlerMod)
  static int _rollHash(int prev, Uint8List data, int pos, int len) {
    var a = prev & 0xffff;
    var b = (prev >> 16) & 0xffff;
    final outByte = data[pos];
    final inByte = data[pos + len];
    a = (a - outByte + inByte) % _adlerMod;
    if (a < 0) a += _adlerMod;
    b = (b - (len * outByte) % _adlerMod + a) % _adlerMod;
    if (b < 0) b += _adlerMod;
    return (b << 16) | a;
  }

  static String _strongHex(Uint8List data, int off, int len) =>
      crypto.md5.convert(Uint8List.sublistView(data, off, off + len)).toString();

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var k = 0; k < a.length; k++) {
      if (a[k] != b[k]) return false;
    }
    return true;
  }

  static ({int value, int next}) _readVarint(Uint8List data, int start) {
    var result = 0;
    var shift = 0;
    var i = start;
    while (true) {
      final byte = data[i++];
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) break;
      shift += 7;
    }
    return (value: result, next: i);
  }
}

class _ByteWriter {
  final BytesBuilder _b = BytesBuilder(copy: false);

  void addByte(int v) => _b.addByte(v);
  void addBytes(List<int> v) => _b.add(v);

  void addVarint(int value) {
    var v = value;
    while (v >= 0x80) {
      _b.addByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    _b.addByte(v);
  }

  Uint8List toBytes() => _b.toBytes();
}
