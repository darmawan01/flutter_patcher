package com.flutter_patcher.flutter_patcher

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PatchManagerTest {
    @Test
    fun validatePatchArgsAcceptsValidFullPatch() {
        val result = PatchManager.validatePatchArgs(
            version = "1.0.0-h1",
            url = "https://example.com/libapp.so",
            md5 = "0123456789abcdef0123456789abcdef",
            mode = "full",
            targetVersionCode = 100,
            currentVersionCode = 100
        )

        assertNull(result)
    }

    @Test
    fun validatePatchArgsRejectsInvalidMd5BeforeDownload() {
        val result = PatchManager.validatePatchArgs(
            version = "1.0.0-h1",
            url = "https://example.com/libapp.so",
            md5 = "bad-md5",
            mode = "full",
            targetVersionCode = 100,
            currentVersionCode = 100
        )

        assertEquals(ApplyErrorCode.INVALID_ARGS, result?.errorCode)
    }

    @Test
    fun validatePatchArgsRejectsTargetVersionCodeMismatch() {
        val result = PatchManager.validatePatchArgs(
            version = "1.0.0-h1",
            url = "https://example.com/libapp.so",
            md5 = "0123456789abcdef0123456789abcdef",
            mode = "full",
            targetVersionCode = 101,
            currentVersionCode = 100
        )

        assertEquals(ApplyErrorCode.INVALID_ARGS, result?.errorCode)
    }

    @Test
    fun validatePatchArgsRejectsUnsupportedMode() {
        val result = PatchManager.validatePatchArgs(
            version = "1.0.0-h1",
            url = "https://example.com/app.patch",
            md5 = "0123456789abcdef0123456789abcdef",
            mode = "delta",
            targetVersionCode = 100,
            currentVersionCode = 100
        )

        assertEquals(ApplyErrorCode.INVALID_ARGS, result?.errorCode)
    }

    @Test
    fun validatePatchArgsAcceptsBlankMd5() {
        val result = PatchManager.validatePatchArgs(
            version = "1.0.0-h1",
            url = "https://example.com/libapp.so",
            md5 = "",
            mode = "full",
            targetVersionCode = 100,
            currentVersionCode = 100
        )

        assertNull(result)
    }

    @Test
    fun validatePatchArgsRejectsBlankVersionOrUrl() {
        val r1 = PatchManager.validatePatchArgs(
            version = "",
            url = "https://example.com/libapp.so",
            md5 = "",
            mode = "full",
            targetVersionCode = 100,
            currentVersionCode = 100
        )
        val r2 = PatchManager.validatePatchArgs(
            version = "1.0.0-h1",
            url = "",
            md5 = "",
            mode = "full",
            targetVersionCode = 100,
            currentVersionCode = 100
        )
        assertEquals(ApplyErrorCode.INVALID_ARGS, r1?.errorCode)
        assertEquals(ApplyErrorCode.INVALID_ARGS, r2?.errorCode)
    }

    @Test
    fun isSameInstalledPatchMatchesByVersionWhenMd5Blank() {
        val installed = "1.0.0-h1" to "0123456789abcdef0123456789abcdef"
        // 入参 md5 为空 → 仅按 version 判等
        assertTrue(PatchManager.isSameInstalledPatch(installed, "1.0.0-h1", ""))
        assertFalse(PatchManager.isSameInstalledPatch(installed, "1.0.0-h2", ""))
    }

    @Test
    fun isSameInstalledPatchRequiresVersionAndMd5Match() {
        val installed = "1.0.0-h1" to "0123456789abcdef0123456789abcdef"

        assertTrue(
            PatchManager.isSameInstalledPatch(
                installed,
                "1.0.0-h1",
                "0123456789ABCDEF0123456789ABCDEF"
            )
        )
        assertFalse(
            PatchManager.isSameInstalledPatch(
                installed,
                "1.0.0-h1",
                "ffffffffffffffffffffffffffffffff"
            )
        )
        assertFalse(
            PatchManager.isSameInstalledPatch(
                installed,
                "1.0.0-h2",
                "0123456789abcdef0123456789abcdef"
            )
        )
    }
}
