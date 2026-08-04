package app.dayflow.android

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ChromeOsCapabilitiesTest {
    @Test
    fun chromeOsLargeWindowEnablesAdaptiveCapabilities() {
        val capabilities = ChromeOsCapabilities.fromSignals(
            isChromeOs = true,
            smallestScreenWidthDp = 768,
            screenWidthDp = 1200,
        )

        assertTrue(capabilities.isChromeOs)
        assertTrue(capabilities.supportsMultiWindow)
        assertTrue(capabilities.isLargeScreen)
        assertEquals(1200, capabilities.contentMaxWidthDp)
        assertEquals(32, capabilities.contentPaddingDp)
        assertEquals(20, capabilities.contentSpacingDp)
    }

    @Test
    fun phoneWindowDoesNotPretendToBeChromebookOrMultiWindow() {
        val capabilities = ChromeOsCapabilities.fromSignals(
            isChromeOs = false,
            smallestScreenWidthDp = 360,
            screenWidthDp = 360,
        )

        assertFalse(capabilities.isChromeOs)
        assertFalse(capabilities.supportsMultiWindow)
        assertFalse(capabilities.isLargeScreen)
        assertEquals(720, capabilities.contentMaxWidthDp)
        assertEquals(24, capabilities.contentPaddingDp)
        assertEquals(16, capabilities.contentSpacingDp)
    }

    @Test
    fun resizedChromeOsWindowKeepsArcIdentityButUpdatesLayoutFlags() {
        val capabilities = ChromeOsCapabilities.fromSignals(
            isChromeOs = true,
            smallestScreenWidthDp = 480,
            screenWidthDp = 800,
        )

        assertTrue(capabilities.isChromeOs)
        assertFalse(capabilities.supportsMultiWindow)
        assertTrue(capabilities.isLargeScreen)
        assertEquals(1200, capabilities.contentMaxWidthDp)
        assertEquals(32, capabilities.contentPaddingDp)
        assertEquals(16, capabilities.contentSpacingDp)
    }
}
