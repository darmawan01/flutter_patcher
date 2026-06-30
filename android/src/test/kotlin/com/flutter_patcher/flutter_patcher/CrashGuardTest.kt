package com.flutter_patcher.flutter_patcher

import android.content.Context
import android.content.SharedPreferences
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.mockito.Mockito

/**
 * Unit tests for the crash-loop circuit breaker, focused on the boot-token +
 * watchdog accumulation that [CrashGuard.markFirstFrame] / [CrashGuard.markBootHealthy]
 * fix: crash_count must NOT reset at first frame, only after the watchdog window,
 * so a render-then-crash patch accumulates across boots until it trips.
 *
 * The ExitInfo (API 30+) path needs a real ActivityManager, so these tests drive
 * the pre-first-frame / Dart-reported crash path (the API<30 fallback + Dart hook),
 * which is pure SharedPreferences state and deterministically testable.
 */
class CrashGuardTest {

    private fun guard(prefs: FakeSharedPreferences, filesDir: File): CrashGuard {
        val context = Mockito.mock(Context::class.java)
        Mockito.`when`(context.getSharedPreferences(Mockito.anyString(), Mockito.anyInt()))
            .thenReturn(prefs)
        Mockito.`when`(context.filesDir).thenReturn(filesDir)
        Mockito.`when`(context.packageName).thenReturn("com.test")
        return CrashGuard(context)
    }

    private fun tempDir(): File =
        File(System.getProperty("java.io.tmpdir"), "cg_test_${System.nanoTime()}").apply { mkdirs() }

    @Test
    fun firstFrameClearsLoadingButKeepsCrashCount() {
        val prefs = FakeSharedPreferences(
            mutableMapOf(
                PatcherConfig.KEY_PATCH_LOADING to true,
                PatcherConfig.KEY_CRASH_COUNT to 1,
            )
        )
        guard(prefs, tempDir()).markFirstFrame()

        assertEquals(false, prefs.getBoolean(PatcherConfig.KEY_PATCH_LOADING, true))
        assertEquals(1, prefs.getInt(PatcherConfig.KEY_CRASH_COUNT, -1)) // NOT reset
    }

    @Test
    fun bootHealthyResetsCrashCount() {
        val prefs = FakeSharedPreferences(mutableMapOf(PatcherConfig.KEY_CRASH_COUNT to 3))
        guard(prefs, tempDir()).markBootHealthy()
        assertEquals(0, prefs.getInt(PatcherConfig.KEY_CRASH_COUNT, -1))
    }

    @Test
    fun renderThenCrashLoopAccumulatesAndTripsAtThreshold() {
        // maxCrashCount=2: a patch that reaches first frame then crashes (Dart-reported)
        // must still trip on the SECOND crash, because first frame no longer resets the count.
        val prefs = FakeSharedPreferences(mutableMapOf(PatcherConfig.KEY_MAX_CRASH to 2))
        val filesDir = tempDir()
        val patchDir = File(filesDir, PatcherConfig.PATCH_DIR).apply { mkdirs() }
        File(patchDir, "libapp_patch.so").writeText("patch")

        // Boot 1: render first frame (no reset), then crash after the frame.
        guard(prefs, filesDir).markFirstFrame()
        var tripped = false
        guard(prefs, filesDir).reportDartBootError("boom") { tripped = true }
        assertFalse(tripped, "1st crash must not trip when threshold=2")
        assertEquals(1, prefs.getInt(PatcherConfig.KEY_CRASH_COUNT, -1))
        assertTrue(patchDir.exists(), "patch must survive the 1st crash")

        // Boot 2: render first frame again (still no reset — the fix), then crash again.
        guard(prefs, filesDir).markFirstFrame()
        assertEquals(1, prefs.getInt(PatcherConfig.KEY_CRASH_COUNT, -1), "first frame must not reset count")
        guard(prefs, filesDir).reportDartBootError("boom again") { tripped = true }
        assertTrue(tripped, "2nd crash must trip at threshold=2")
        assertFalse(patchDir.exists(), "patch must be dropped once tripped")
    }

    @Test
    fun healthyBootBetweenCrashesResetsAccumulation() {
        // Crash once, then survive a full healthy boot → counter resets → no premature trip.
        val prefs = FakeSharedPreferences(mutableMapOf(PatcherConfig.KEY_MAX_CRASH to 2))
        val filesDir = tempDir()
        File(filesDir, PatcherConfig.PATCH_DIR).apply { mkdirs() }

        guard(prefs, filesDir).reportDartBootError("boom") {}
        assertEquals(1, prefs.getInt(PatcherConfig.KEY_CRASH_COUNT, -1))

        guard(prefs, filesDir).markFirstFrame()
        guard(prefs, filesDir).markBootHealthy() // survived the window
        assertEquals(0, prefs.getInt(PatcherConfig.KEY_CRASH_COUNT, -1))
    }
}

/** Minimal in-memory [SharedPreferences] for pure-JVM unit tests. */
class FakeSharedPreferences(
    private val map: MutableMap<String, Any?> = mutableMapOf(),
) : SharedPreferences {

    inner class FakeEditor : SharedPreferences.Editor {
        private val pending = mutableMapOf<String, Any?>()
        private val removals = mutableSetOf<String>()
        private var clear = false

        override fun putString(key: String, value: String?) = apply { pending[key] = value }
        override fun putStringSet(key: String, values: MutableSet<String>?) = apply { pending[key] = values }
        override fun putInt(key: String, value: Int) = apply { pending[key] = value }
        override fun putLong(key: String, value: Long) = apply { pending[key] = value }
        override fun putFloat(key: String, value: Float) = apply { pending[key] = value }
        override fun putBoolean(key: String, value: Boolean) = apply { pending[key] = value }
        override fun remove(key: String) = apply { removals.add(key) }
        override fun clear() = apply { clear = true }

        private fun flush() {
            if (clear) map.clear()
            removals.forEach { map.remove(it) }
            map.putAll(pending)
            pending.clear(); removals.clear(); clear = false
        }

        override fun commit(): Boolean { flush(); return true }
        override fun apply() { flush() }
    }

    override fun getAll(): MutableMap<String, *> = map
    @Suppress("UNCHECKED_CAST")
    override fun getString(key: String, defValue: String?) = map[key] as? String ?: defValue
    @Suppress("UNCHECKED_CAST")
    override fun getStringSet(key: String, defValues: MutableSet<String>?) =
        map[key] as? MutableSet<String> ?: defValues
    override fun getInt(key: String, defValue: Int) = (map[key] as? Int) ?: defValue
    override fun getLong(key: String, defValue: Long) = (map[key] as? Long) ?: defValue
    override fun getFloat(key: String, defValue: Float) = (map[key] as? Float) ?: defValue
    override fun getBoolean(key: String, defValue: Boolean) = (map[key] as? Boolean) ?: defValue
    override fun contains(key: String) = map.containsKey(key)
    override fun edit(): SharedPreferences.Editor = FakeEditor()
    override fun registerOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}
    override fun unregisterOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}
}
