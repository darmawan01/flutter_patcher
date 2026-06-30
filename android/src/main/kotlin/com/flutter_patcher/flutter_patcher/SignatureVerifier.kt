package com.flutter_patcher.flutter_patcher

import android.util.Base64
import android.util.Log
import java.io.File
import java.security.MessageDigest
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer

/**
 * 补丁文件完整性与签名校验。
 *
 * 策略：
 * - SHA-256 完整性校验：始终执行（来自 [com.flutter_patcher.flutter_patcher.PatchInfo.sha256]）
 * - Ed25519 签名：
 *   - signature 为空 → 跳过（仅靠 SHA-256 + 传输层防篡改）
 *   - signature 非空 → 使用 BouncyCastle 轻量级实现验签，不依赖平台 JCA provider，
 *     在所有受支持的 API 级别（24+）上一致工作
 *
 * 签名的消息体约定为 **SHA-256 小写 hex 字符串的 UTF-8 字节**，
 * 与 Dart 侧 PatchInfo.signature 含义保持一致。MD5 是碰撞可构造的，
 * 绝不用作签名消息——见 [md5] 的注释。
 */
internal object SignatureVerifier {

    private const val TAG = "FlutterPatcher/Sig"

    private fun digestHex(file: File, algorithm: String): String {
        val digest = MessageDigest.getInstance(algorithm)
        file.inputStream().use { input ->
            val buf = ByteArray(8192)
            while (true) {
                val n = input.read(buf)
                if (n <= 0) break
                digest.update(buf, 0, n)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * SHA-256 of a file (lower-case hex). This is the security-relevant hash:
     * it is the integrity check for the signed payload AND the message the
     * Ed25519 signature is computed over. Use this — never MD5 — for anything
     * that a signature protects.
     */
    fun sha256(file: File): String = digestHex(file, "SHA-256")

    /**
     * MD5 of a file (lower-case hex). Retained ONLY for non-security corruption
     * checks of inner patch.zip entries (asset/lib payloads). Never use for the
     * signed value — MD5 is collision-broken.
     */
    fun md5(file: File): String = digestHex(file, "MD5")

    /**
     * 仅校验 Ed25519 签名（调用方已确认 MD5 匹配）。
     *
     * - signature 为空 → 跳过返回 true
     * - signature 非空但 publicKey 未配置 → 拒绝
     * - API < 33 且 strictSignature=true → 拒绝（防止降级攻击）
     * - API < 33 且 strictSignature=false → 跳过返回 true
     * - API >= 33 → 真实 Ed25519 验签
     *
     * @param signedMessage 签名所覆盖的消息体（TUF 风格的规范化 manifest 字符串，
     *   绑定 version/patchNumber/targetVersionCode/sha256；调用方与签名方必须逐字节一致）
     */
    fun verifySignatureOnly(
        signedMessage: String,
        signatureBase64: String,
        publicKeyBase64: String,
        strictSignature: Boolean = true
    ): Boolean {
        val sig = signatureBase64.trim()
        if (sig.isEmpty() || sig.equals("null", ignoreCase = true)) {
            Log.d(TAG, "signature empty, skip Ed25519 check")
            return true
        }
        if (publicKeyBase64.isEmpty()) {
            Log.w(TAG, "signature present but no public key configured, reject")
            return false
        }

        // Ed25519 verification uses the bundled BouncyCastle lightweight crypto API,
        // so it no longer depends on platform JCA provider availability. That means it
        // works on every supported API level (24+), including API < 33 — the old
        // SDK_INT < 33 rejection is gone.
        return try {
            verifyEd25519(signedMessage, sig, publicKeyBase64)
        } catch (e: Exception) {
            Log.e(TAG, "Ed25519 verify failed", e)
            false
        }
    }

    /**
     * [verify] 的细粒度结果。调用方据此可区分"被丢弃的具体原因"用于诊断上报，
     * 见 [BootDiagnosticStore.DROPPED_MD5_MISMATCH] / [BootDiagnosticStore.DROPPED_SIGNATURE_INVALID]。
     */
    enum class VerifyResult { OK, MD5_MISMATCH, SIGNATURE_INVALID }

    /**
     * 完整校验（细粒度版本）：SHA-256 完整性 + 可选 Ed25519。返回失败原因分类。
     *
     * 注意：[expectedSha256] 为空时整体跳过完整性与签名校验，直接返回
     * [VerifyResult.OK]（调用方明确选择"不下发 hash"，仅依赖 HTTPS）。
     * 启动路径目前仍依赖 meta.effectiveSha256 非空，故启动期不会走到这条分支；
     * 该分支主要服务于 [PatchManager.applyPatch] 期间的重复使用。
     */
    fun verifyDetailed(
        file: File,
        expectedSha256: String,
        signedMessage: String,
        signatureBase64: String,
        publicKeyBase64: String,
        strictSignature: Boolean = true
    ): VerifyResult {
        if (expectedSha256.isEmpty()) {
            Log.w(TAG, "expected sha256 empty, skip hash & signature verify")
            return VerifyResult.OK
        }
        val actualSha256 = sha256(file)
        if (!actualSha256.equals(expectedSha256, ignoreCase = true)) {
            Log.e(TAG, "sha256 mismatch: expected=$expectedSha256, actual=$actualSha256")
            return VerifyResult.MD5_MISMATCH
        }
        return if (verifySignatureOnly(
                signedMessage,
                signatureBase64,
                publicKeyBase64,
                strictSignature
            )
        ) {
            VerifyResult.OK
        } else {
            VerifyResult.SIGNATURE_INVALID
        }
    }

    /**
     * 完整校验：SHA-256 完整性 + 可选 Ed25519。
     *
     * @param file             已下载的补丁文件
     * @param expectedSha256   manifest 中的预期 SHA-256（小写 hex，64 字符）
     * @param signatureBase64  manifest 中的 Ed25519 签名（Base64，允许为空）
     * @param publicKeyBase64  X.509 SubjectPublicKeyInfo 的 Base64 公钥（允许为空）
     * @param strictSignature  API < 33 是否拒绝签名校验（默认 true，安全）
     * @return 是否通过校验
     */
    fun verify(
        file: File,
        expectedSha256: String,
        signedMessage: String,
        signatureBase64: String,
        publicKeyBase64: String,
        strictSignature: Boolean = true
    ): Boolean = verifyDetailed(
        file, expectedSha256, signedMessage, signatureBase64, publicKeyBase64, strictSignature
    ) == VerifyResult.OK

    /**
     * 规范化 manifest 字符串（TUF 风格：签名覆盖元数据而非仅 blob 哈希）。
     *
     * 绑定 version + patchNumber + targetVersionCode + sha256，逐字节固定：
     * 字段顺序固定、`\n` 连接、无尾换行。签名方（pack/sign 工具）与设备端必须
     * 用**完全相同**的构造，否则验签失败。改动格式必须同步升级 `v1` 版本前缀。
     */
    fun canonicalManifest(
        version: String,
        patchNumber: Long,
        targetVersionCode: Long,
        sha256: String
    ): String = buildString {
        append("flutter_patcher.manifest.v1\n")
        append("version=").append(version).append('\n')
        append("patchNumber=").append(patchNumber).append('\n')
        append("targetVersionCode=").append(targetVersionCode).append('\n')
        append("sha256=").append(sha256.lowercase())
    }

    private fun verifyEd25519(
        hashHex: String,
        signatureBase64: String,
        publicKeyBase64: String
    ): Boolean {
        val pkBytes = Base64.decode(publicKeyBase64, Base64.NO_WRAP)
        // Accept either a raw 32-byte Ed25519 key or a full X.509 SubjectPublicKeyInfo
        // (44 bytes: 12-byte header + 32-byte key). For Ed25519 the raw key is always
        // the trailing 32 bytes, so this works for both encodings.
        val raw = when {
            pkBytes.size == ED25519_KEY_LEN -> pkBytes
            pkBytes.size > ED25519_KEY_LEN ->
                pkBytes.copyOfRange(pkBytes.size - ED25519_KEY_LEN, pkBytes.size)
            else -> {
                Log.e(TAG, "invalid Ed25519 public key length: ${pkBytes.size}")
                return false
            }
        }

        val publicKey = Ed25519PublicKeyParameters(raw, 0)
        val msg = hashHex.toByteArray(Charsets.UTF_8)
        val sigBytes = Base64.decode(signatureBase64, Base64.NO_WRAP)

        val signer = Ed25519Signer()
        signer.init(false, publicKey)
        signer.update(msg, 0, msg.size)
        return signer.verifySignature(sigBytes)
    }

    private const val ED25519_KEY_LEN = 32
}
