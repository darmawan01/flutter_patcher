package com.flutter_patcher.flutter_patcher

import java.io.ByteArrayOutputStream

/**
 * Applies a binary delta produced by the Dart `DeltaCodec` (magic "FPD1") to a
 * base byte array, reconstructing the target. The op stream is trivial — COPY a
 * range of the base, or INSERT literal bytes — so this applier is small and has
 * no cleverness to get wrong; the caller still SHA-256-verifies the result.
 *
 * Format (LEB128 unsigned varints):
 *   magic "FPD1"
 *   repeated:
 *     0x00 COPY:   varint baseOffset, varint length
 *     0x01 INSERT: varint length, length literal bytes
 */
internal object DeltaPatch {

    private val MAGIC = byteArrayOf(0x46, 0x50, 0x44, 0x31) // "FPD1"
    private const val OP_COPY = 0x00
    private const val OP_INSERT = 0x01

    class DeltaFormatException(message: String) : RuntimeException(message)

    fun apply(base: ByteArray, delta: ByteArray): ByteArray {
        var i = 0
        for (m in MAGIC) {
            if (i >= delta.size || delta[i] != m) throw DeltaFormatException("bad delta magic")
            i++
        }
        // Pre-size to the base length as a reasonable starting capacity.
        val out = ByteArrayOutputStream(base.size)
        while (i < delta.size) {
            val op = delta[i++].toInt() and 0xff
            when (op) {
                OP_COPY -> {
                    val (baseOff, n1) = readVarint(delta, i); i = n1
                    val (len, n2) = readVarint(delta, i); i = n2
                    // Subtract instead of `baseOff + len` so a hostile varint can't
                    // overflow Int and wrap past the bounds check.
                    if (baseOff < 0 || len < 0 || baseOff > base.size - len) {
                        throw DeltaFormatException("COPY out of range: off=$baseOff len=$len base=${base.size}")
                    }
                    out.write(base, baseOff, len)
                }
                OP_INSERT -> {
                    val (len, n1) = readVarint(delta, i); i = n1
                    if (len < 0 || len > delta.size - i) {
                        throw DeltaFormatException("INSERT out of range: len=$len")
                    }
                    out.write(delta, i, len)
                    i += len
                }
                else -> throw DeltaFormatException("bad delta op $op")
            }
        }
        return out.toByteArray()
    }

    private fun readVarint(data: ByteArray, start: Int): Pair<Int, Int> {
        var result = 0
        var shift = 0
        var i = start
        while (true) {
            if (i >= data.size) throw DeltaFormatException("truncated varint")
            val b = data[i++].toInt() and 0xff
            result = result or ((b and 0x7f) shl shift)
            if (b and 0x80 == 0) break
            shift += 7
        }
        return Pair(result, i)
    }
}
