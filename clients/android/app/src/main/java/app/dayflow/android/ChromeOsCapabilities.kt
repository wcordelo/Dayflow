package app.dayflow.android

import android.content.Context
import android.content.pm.PackageManager

data class ChromeOsCapabilities(
    val isChromeOs: Boolean,
    val supportsMultiWindow: Boolean,
    val isLargeScreen: Boolean,
) {
    /**
     * Keep the adaptive layout decision next to the capability signals rather
     * than scattering Chromebook checks through the Compose tree. The values
     * are deliberately plain integers so the policy can be tested without an
     * Android window or a device configuration.
     */
    val contentMaxWidthDp: Int
        get() = if (isLargeScreen) 1200 else 720

    val contentPaddingDp: Int
        get() = if (isChromeOs && isLargeScreen) 32 else 24

    val contentSpacingDp: Int
        get() = if (supportsMultiWindow) 20 else 16

    companion object {
        fun detect(context: Context): ChromeOsCapabilities {
            val packageManager = context.packageManager
            val configuration = context.resources.configuration
            return fromSignals(
                isChromeOs = packageManager.hasSystemFeature("org.chromium.arc"),
                smallestScreenWidthDp = configuration.smallestScreenWidthDp,
                screenWidthDp = configuration.screenWidthDp,
            )
        }

        fun fromSignals(
            isChromeOs: Boolean,
            smallestScreenWidthDp: Int,
            screenWidthDp: Int,
        ): ChromeOsCapabilities {
            return ChromeOsCapabilities(
                isChromeOs = isChromeOs,
                supportsMultiWindow = smallestScreenWidthDp >= 600,
                isLargeScreen = screenWidthDp >= 600,
            )
        }
    }
}
