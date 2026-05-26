package com.flutter_patcher.flutter_patcher

import kotlin.test.Test
import kotlin.test.assertEquals

class LoaderHookTest {
    @Test
    fun patchedAssetLookupKeysUseBundlePath() {
        assertEquals(
            "flutter_patcher_assets/images/hero.png",
            patchedAssetLookupKey(
                "flutter_patcher_assets",
                "images/hero.png"
            )
        )
        assertEquals(
            "flutter_patcher_assets/packages/demo/images/hero.png",
            patchedPackageAssetLookupKey(
                "flutter_patcher_assets",
                "images/hero.png",
                "demo"
            )
        )
    }
}
