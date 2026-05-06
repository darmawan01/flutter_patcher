package com.flutter_patcher.flutter_patcher

import android.content.Context
import android.os.SystemClock
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL

/**
 * 补丁应用过程的阶段 / 进度回调。
 *
 * - `phase`：见 [Phase]
 * - `received` / `total`：仅 `phase=downloading` 时有意义；`total=-1` 表示
 *   服务端未返回 Content-Length
 */
internal typealias ProgressCallback = (phase: String, received: Long, total: Long) -> Unit

internal object Phase {
    const val DOWNLOADING = "downloading"
    const val VERIFYING = "verifying"
    const val FINALIZING = "finalizing"
}

/**
 * 补丁生命周期管理：下载、验签、落盘、回滚、查询路径。
 *
 * 所有外部输入（URL、md5、signature、版本号）都从入参读取，
 * 不依赖任何硬编码配置。
 *
 * [progress] 可选，用于把各阶段 / 下载进度同步到 UI（由 Plugin 经 EventChannel
 * 送到 Dart 侧）。
 */
internal class PatchManager(
    private val context: Context,
    private val progress: ProgressCallback? = null
) {

    companion object {
        private const val TAG = "FlutterPatcher/Mgr"

        private const val CONNECT_TIMEOUT_MS = 10_000
        private const val READ_TIMEOUT_MS = 30_000
        private const val MAX_RETRIES = 3

        private const val MODE_FULL = "full"
        private val MD5_HEX = Regex("^[0-9a-fA-F]{32}$")

        /** 下载进度节流，避免频繁跨线程发事件淹没 UI。 */
        private const val PROGRESS_EMIT_INTERVAL_MS = 200L

        private val APPLY_LOCK = Any()

        internal fun validatePatchArgs(
            version: String,
            url: String,
            md5: String,
            mode: String,
            targetVersionCode: Long?,
            currentVersionCode: Long
        ): ApplyResult? {
            if (version.isBlank() || url.isBlank() || md5.isBlank()) {
                return ApplyResult.failure(
                    ApplyErrorCode.INVALID_ARGS,
                    "missing version/url/md5"
                )
            }
            if (!MD5_HEX.matches(md5)) {
                return ApplyResult.failure(
                    ApplyErrorCode.INVALID_ARGS,
                    "md5 must be 32 hex chars"
                )
            }
            if (mode != MODE_FULL) {
                return ApplyResult.failure(
                    ApplyErrorCode.INVALID_ARGS,
                    "unsupported mode: $mode; only full patches are supported"
                )
            }
            if (targetVersionCode != null) {
                if (currentVersionCode == PatcherConfig.INVALID_VERSION_CODE) {
                    return ApplyResult.failure(
                        ApplyErrorCode.IO_ERROR,
                        "cannot resolve current app versionCode"
                    )
                }
                if (targetVersionCode != currentVersionCode) {
                    return ApplyResult.failure(
                        ApplyErrorCode.INVALID_ARGS,
                        "targetVersionCode=$targetVersionCode does not match current=$currentVersionCode"
                    )
                }
            }
            return null
        }

        internal fun isSameInstalledPatch(
            currentMeta: Pair<String, String>?,
            version: String,
            md5: String
        ): Boolean {
            if (currentMeta == null) return false
            return currentMeta.first == version &&
                currentMeta.second.equals(md5, ignoreCase = true)
        }
    }

    private val patchDir = File(context.filesDir, PatcherConfig.PATCH_DIR)
    private val patchFile = File(patchDir, PatcherConfig.PATCH_FILENAME)
    private val metaFile = File(patchDir, PatcherConfig.META_FILENAME)
    private val installMarkerFile = File(patchDir, "installing")

    // ==================== 启动路径 ====================

    /**
     * 启动时校验本地补丁是否可用。
     *
     * @param onDrop 可选回调：每次"补丁在盘上但被丢弃"时触发，携带分类原因 +
     *   被丢弃的版本号 + 上下文 extras。专为 [BootDiagnosticStore] 上报使用，
     *   不影响主流程。补丁文件本身缺失（首次安装 / pm clear）**不会** 触发，
     *   该场景由调用方按 NO_PATCH 兜底。
     */
    fun getValidPatchPath(
        onDrop: ((status: String, version: String?, extras: Map<String, Any?>) -> Unit)? = null
    ): String? {
        if (installMarkerFile.exists()) {
            Log.w(TAG, "previous patch install was interrupted, drop patch dir")
            onDrop?.invoke(
                BootDiagnosticStore.DROPPED_META_CORRUPTED,
                null,
                mapOf("message" to "patch install interrupted")
            )
            deletePatch()
            return null
        }
        if (!patchFile.exists() || !metaFile.exists()) return null

        val meta = readMeta()
        if (meta == null) {
            Log.e(TAG, "meta.json unparseable, drop patch")
            onDrop?.invoke(
                BootDiagnosticStore.DROPPED_META_CORRUPTED,
                null,
                mapOf("message" to "meta.json missing or unparseable")
            )
            deletePatch()
            return null
        }
        val version = meta.optString("version", "").ifEmpty { null }

        // versionCode 兼容性校验：宿主 APK 升级 / 安装时包名冲突场景下，旧补丁
        // 与当前 Flutter engine & Dart kernel 可能不兼容，直接丢弃避免启动崩溃。
        // 没有字段的旧 meta（-1 sentinel）同样视为不可信，安全丢弃。
        val patchVc = meta.optLong(
            PatcherConfig.META_KEY_TARGET_VERSION_CODE,
            PatcherConfig.INVALID_VERSION_CODE
        )
        val currentVc = PatcherConfig.currentVersionCode(context)
        if (patchVc == PatcherConfig.INVALID_VERSION_CODE ||
            currentVc == PatcherConfig.INVALID_VERSION_CODE ||
            patchVc != currentVc
        ) {
            Log.w(TAG, "versionCode mismatch: patch=$patchVc current=$currentVc, drop patch")
            onDrop?.invoke(
                BootDiagnosticStore.DROPPED_VERSION_CODE_MISMATCH,
                version,
                mapOf(
                    "patchTargetVersionCode" to patchVc,
                    "appVersionCode" to currentVc,
                    "message" to "patch built for vc=$patchVc, app is vc=$currentVc"
                )
            )
            deletePatch()
            return null
        }

        // 落盘时已把「合成后」的 md5 写入 meta.effectiveMd5
        val expectedMd5 = meta.optString("effectiveMd5", "")
        val signature = meta.optString("signature", "")
        val publicKey = PatcherConfig.publicKey(context)
        val strictSignature = PatcherConfig.strictSignature(context)

        if (expectedMd5.isEmpty()) {
            Log.e(TAG, "meta.effectiveMd5 missing, drop patch")
            onDrop?.invoke(
                BootDiagnosticStore.DROPPED_META_CORRUPTED,
                version,
                mapOf("message" to "meta.effectiveMd5 missing")
            )
            deletePatch()
            return null
        }
        val verifyResult = SignatureVerifier.verifyDetailed(
            patchFile, expectedMd5, signature, publicKey, strictSignature
        )
        if (verifyResult != SignatureVerifier.VerifyResult.OK) {
            Log.e(TAG, "verify failed: $verifyResult, drop patch")
            val status = when (verifyResult) {
                SignatureVerifier.VerifyResult.MD5_MISMATCH ->
                    BootDiagnosticStore.DROPPED_MD5_MISMATCH
                SignatureVerifier.VerifyResult.SIGNATURE_INVALID ->
                    BootDiagnosticStore.DROPPED_SIGNATURE_INVALID
                SignatureVerifier.VerifyResult.OK -> error("unreachable")
            }
            // 黑名单使用 downloadMd5：它与 applyPatch 入参 md5 保持一致。
            onDrop?.invoke(
                status,
                version,
                mapOf(
                    "blacklistMd5" to meta.optString("downloadMd5", expectedMd5),
                    "message" to "SignatureVerifier returned $verifyResult",
                )
            )
            deletePatch()
            return null
        }
        if (!patchFile.canRead()) patchFile.setReadable(true, false)
        return patchFile.absolutePath
    }

    fun currentVersion(): String = readMeta()?.optString("version", "") ?: ""

    /**
     * 当前补丁元信息快照。返回 (version, downloadMd5) 二元组，或 null（无补丁 / meta 损坏）。
     * 供 [BlacklistStore] 在丢弃补丁前读取双键。
     */
    fun currentMeta(): Pair<String, String>? {
        val meta = readMeta() ?: return null
        val version = meta.optString("version", "")
        val md5 = meta.optString("downloadMd5", meta.optString("effectiveMd5", ""))
        if (version.isEmpty() || md5.isEmpty()) return null
        return version to md5
    }

    // ==================== 安装 ====================

    fun applyPatch(info: Map<String, Any?>): ApplyResult = synchronized(APPLY_LOCK) {
        val version = (info["version"] as? String).orEmpty()
        val url = (info["patchUrl"] as? String).orEmpty()
        val md5 = (info["md5"] as? String).orEmpty()
        val signature = (info["signature"] as? String).orEmpty()
        val mode = ((info["mode"] as? String) ?: MODE_FULL).lowercase()
        val hasTargetVersionCode = info.containsKey("targetVersionCode")
        val serverTargetVc = (info["targetVersionCode"] as? Number)?.toLong()
        if (hasTargetVersionCode && serverTargetVc == null) {
            return ApplyResult.failure(
                ApplyErrorCode.INVALID_ARGS,
                "targetVersionCode must be a number"
            )
        }
        val currentVc = PatcherConfig.currentVersionCode(context)

        validatePatchArgs(
            version = version,
            url = url,
            md5 = md5,
            mode = mode,
            targetVersionCode = serverTargetVc,
            currentVersionCode = currentVc
        )?.let {
            Log.w(TAG, "applyPatch: ${it.message}")
            return it
        }
        if (serverTargetVc == null && currentVc == PatcherConfig.INVALID_VERSION_CODE) {
            return ApplyResult.failure(
                ApplyErrorCode.IO_ERROR,
                "cannot resolve current app versionCode"
            )
        }
        // 黑名单查询前置：在下载之前拦截，避免对已知坏补丁浪费流量。
        // 服务端再下发同一份 (version, md5) 也立即拒绝。
        if (BlacklistStore.contains(context, version, md5)) {
            Log.w(TAG, "applyPatch: (version=$version, md5=$md5) is blacklisted, reject")
            return ApplyResult.failure(
                ApplyErrorCode.BLACKLISTED,
                "patch (version=$version, md5=$md5) was previously blacklisted; " +
                    "call FlutterPatcher.clearBlacklist() to reset (debug only)"
            )
        }
        if (isSameInstalledPatch(currentMeta(), version, md5)) {
            Log.d(TAG, "patch $version with md5=$md5 already installed")
            return ApplyResult.SUCCESS
        }

        patchDir.mkdirs()
        val downloaded = File(patchDir, "temp_download.bin")
        var lastNetworkError: String? = null

        for (attempt in 1..MAX_RETRIES) {
            try {
                progress?.invoke(Phase.DOWNLOADING, 0L, -1L)
                downloadTo(url, downloaded) { received, total ->
                    progress?.invoke(Phase.DOWNLOADING, received, total)
                }
                Log.d(TAG, "download ok: ${downloaded.length()} bytes (attempt=$attempt)")

                // Step 1: MD5（区分于签名错误，给出独立错误码）
                progress?.invoke(Phase.VERIFYING, 0L, 0L)
                val actualMd5 = SignatureVerifier.md5(downloaded)
                if (!actualMd5.equals(md5, ignoreCase = true)) {
                    Log.e(TAG, "md5 mismatch: expected=$md5 actual=$actualMd5")
                    downloaded.delete()
                    return ApplyResult.failure(
                        ApplyErrorCode.MD5_MISMATCH,
                        "expected=$md5 actual=$actualMd5"
                    )
                }

                // Step 2: signature
                val publicKey = PatcherConfig.publicKey(context)
                val strictSignature = PatcherConfig.strictSignature(context)
                if (!SignatureVerifier.verifySignatureOnly(
                        actualMd5.lowercase(), signature, publicKey, strictSignature
                    )
                ) {
                    Log.e(TAG, "signature verify failed")
                    downloaded.delete()
                    return ApplyResult.failure(
                        ApplyErrorCode.SIGNATURE_INVALID,
                        "ed25519 signature verify failed"
                    )
                }

                val finalSo = downloaded
                val effectiveMd5 = md5

                // targetVersionCode：优先取服务端下发；否则以当下宿主 APK 的
                // versionCode 兜底写入。启动时会强校验此字段 == 当前 APK versionCode。
                val targetVersionCode = serverTargetVc ?: currentVc

                val meta = JSONObject().apply {
                    put("version", version)
                    put("downloadMd5", md5)
                    put("effectiveMd5", effectiveMd5)
                    put("signature", signature)
                    put(PatcherConfig.META_KEY_TARGET_VERSION_CODE, targetVersionCode)
                    put("installed_at", System.currentTimeMillis())
                }
                progress?.invoke(Phase.FINALIZING, 0L, 0L)
                finalizePatch(finalSo, meta)?.let { return it }

                CrashGuard(context).reset()

                Log.d(TAG, "patch $version ready, takes effect on next cold start")
                return ApplyResult.SUCCESS
            } catch (e: Exception) {
                Log.w(TAG, "attempt=$attempt failed: ${e.message}")
                lastNetworkError = e.message
                downloaded.delete()
                if (attempt < MAX_RETRIES) {
                    val backoff = 2000L * (1L shl (attempt - 1))
                    try {
                        Thread.sleep(backoff)
                    } catch (_: InterruptedException) {
                        return ApplyResult.failure(
                            ApplyErrorCode.NETWORK,
                            "interrupted during backoff"
                        )
                    }
                }
            }
        }
        return ApplyResult.failure(
            ApplyErrorCode.NETWORK,
            "download failed after $MAX_RETRIES attempts: $lastNetworkError"
        )
    }

    // ==================== 回滚 ====================

    fun rollback() {
        deletePatch()
        CrashGuard(context).reset()
        Log.d(TAG, "rolled back to built-in version")
    }

    private fun finalizePatch(finalSo: File, meta: JSONObject): ApplyResult? {
        val pendingSo = File(patchDir, "${PatcherConfig.PATCH_FILENAME}.pending")
        val pendingMeta = File(patchDir, "${PatcherConfig.META_FILENAME}.pending")
        var touchedFinal = false
        var committed = false
        return try {
            pendingSo.delete()
            pendingMeta.delete()
            installMarkerFile.delete()

            if (!finalSo.renameTo(pendingSo)) {
                finalSo.delete()
                return ApplyResult.failure(
                    ApplyErrorCode.IO_ERROR,
                    "rename to ${pendingSo.absolutePath} failed"
                )
            }
            writeTextSync(pendingMeta, meta.toString())
            writeTextSync(installMarkerFile, "installing")

            if (patchFile.exists() && !patchFile.delete()) {
                return ApplyResult.failure(
                    ApplyErrorCode.IO_ERROR,
                    "delete ${patchFile.absolutePath} failed"
                )
            }
            touchedFinal = true
            if (!pendingSo.renameTo(patchFile)) {
                return ApplyResult.failure(
                    ApplyErrorCode.IO_ERROR,
                    "rename to ${patchFile.absolutePath} failed"
                )
            }

            if (metaFile.exists() && !metaFile.delete()) {
                return ApplyResult.failure(
                    ApplyErrorCode.IO_ERROR,
                    "delete ${metaFile.absolutePath} failed"
                )
            }
            if (!pendingMeta.renameTo(metaFile)) {
                return ApplyResult.failure(
                    ApplyErrorCode.IO_ERROR,
                    "rename to ${metaFile.absolutePath} failed"
                )
            }

            committed = true
            installMarkerFile.delete()
            null
        } catch (e: Exception) {
            Log.e(TAG, "finalize patch failed", e)
            ApplyResult.failure(ApplyErrorCode.IO_ERROR, e.message ?: e.javaClass.simpleName)
        } finally {
            pendingSo.delete()
            pendingMeta.delete()
            installMarkerFile.delete()
            if (touchedFinal && !committed) {
                deletePatch()
            }
        }
    }

    private fun writeTextSync(file: File, text: String) {
        FileOutputStream(file).use { output ->
            output.write(text.toByteArray(Charsets.UTF_8))
            output.fd.sync()
        }
    }

    // ==================== 内部 ====================

    /**
     * 把 [url] 指向的字节流写入 [dest]，可选 [onBytes] 接收字节级进度。
     *
     * 支持：
     * - `http://` / `https://`：JDK `HttpURLConnection`，minSdk 24+ 自带，不与
     *   宿主工程的 okhttp 版本冲突。不做跨协议重定向：生产环境补丁 URL 直接给 HTTPS。
     * - `file://`：从设备本地路径直读。**主要用于 demo / 本地联调**（用 `adb push`
     *   把手工打好的补丁推到 app 的 external files dir 后，用 file:// 加载）。
     *   生产环境不会用到，但也不会绕过任何校验（md5 / 签名照样跑）。
     */
    private fun downloadTo(
        url: String,
        dest: File,
        onBytes: ((received: Long, total: Long) -> Unit)? = null
    ) {
        val parsed = URL(url)
        when (parsed.protocol?.lowercase()) {
            "http", "https" -> downloadHttp(parsed, dest, onBytes)
            "file" -> copyFromFile(parsed, dest, onBytes)
            else -> throw RuntimeException("unsupported URL scheme: ${parsed.protocol}")
        }
    }

    private fun downloadHttp(
        url: URL,
        dest: File,
        onBytes: ((received: Long, total: Long) -> Unit)?
    ) {
        val conn = url.openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = CONNECT_TIMEOUT_MS
            conn.readTimeout = READ_TIMEOUT_MS
            conn.requestMethod = "GET"
            val code = conn.responseCode
            if (code !in 200..299) throw RuntimeException("HTTP $code")

            val total = conn.contentLengthLong   // -1 表示服务端未发 Content-Length
            streamToFile(conn.inputStream, dest, total, onBytes)
        } finally {
            conn.disconnect()
        }
    }

    private fun copyFromFile(
        url: URL,
        dest: File,
        onBytes: ((received: Long, total: Long) -> Unit)?
    ) {
        // URL.path 对 Unix-like 路径直接给 /data/.../foo
        val src = File(url.path)
        if (!src.exists()) throw RuntimeException("file not found: ${src.absolutePath}")
        if (!src.canRead()) throw RuntimeException("file not readable: ${src.absolutePath}")
        streamToFile(src.inputStream(), dest, src.length(), onBytes)
    }

    private fun streamToFile(
        input: java.io.InputStream,
        dest: File,
        total: Long,
        onBytes: ((received: Long, total: Long) -> Unit)?
    ) {
        var received = 0L
        var lastEmit = 0L
        input.use { ins ->
            dest.outputStream().use { output ->
                val buf = ByteArray(8192)
                while (true) {
                    val n = ins.read(buf)
                    if (n <= 0) break
                    output.write(buf, 0, n)
                    received += n
                    if (onBytes != null) {
                        val now = SystemClock.uptimeMillis()
                        if (now - lastEmit >= PROGRESS_EMIT_INTERVAL_MS) {
                            onBytes(received, total)
                            lastEmit = now
                        }
                    }
                }
                output.fd.sync()
            }
        }
        // 结尾再发一次，保证 UI 能刷到 100%
        onBytes?.invoke(received, total)
    }

    private fun deletePatch() {
        if (patchDir.exists()) patchDir.deleteRecursively()
    }

    private fun readMeta(): JSONObject? {
        if (!metaFile.exists()) return null
        return try {
            JSONObject(metaFile.readText())
        } catch (_: Exception) {
            null
        }
    }
}
