package com.flutter_patcher.flutter_patcher

import kotlin.test.Test
import kotlin.test.assertEquals

class PatcherConfigTest {
    @Test
    fun loaderFieldCandidatesRoundTripPreservesOrder() {
        val encoded = PatcherConfig.encodeLoaderFieldCandidates(
            listOf("firstLoader", "secondLoader", "flutterLoader")
        )

        assertEquals(
            listOf("firstLoader", "secondLoader", "flutterLoader"),
            PatcherConfig.decodeLoaderFieldCandidates(encoded)
        )
    }

    @Test
    fun loaderFieldCandidatesNormalizeBlankAndDuplicateValues() {
        val encoded = PatcherConfig.encodeLoaderFieldCandidates(
            listOf(" flutterLoader ", "", "customLoader", "flutterLoader")
        )

        assertEquals(
            listOf("flutterLoader", "customLoader"),
            PatcherConfig.decodeLoaderFieldCandidates(encoded)
        )
    }
}
