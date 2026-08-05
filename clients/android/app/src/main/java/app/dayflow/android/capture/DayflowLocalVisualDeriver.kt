package app.dayflow.android.capture

import android.media.Image
import kotlin.math.max
import kotlin.math.min

/**
 * Produces a bounded semantic card from a frame while the frame is still in
 * memory. Only the small visual profile and the resulting card leave this
 * function; the Image is always released by the caller.
 */
data class DayflowLocalDerivedCard(
    val title: String,
    val summary: String,
    val category: String,
    val derivationMode: String,
)

internal data class DayflowVisualProfile(
    val tone: String,
    val contrast: String,
)

object DayflowLocalVisualDeriver {
    const val DERIVATION_MODE = "privacy_gated_local_visual_v1"

    fun derive(image: Image, applicationId: String?): DayflowLocalDerivedCard {
        val profile = profile(image)
        val category = categoryFor(applicationId)
        val title = when (category) {
            "focus" -> "Focused work session"
            "communication" -> "Communication session"
            "research" -> "Research session"
            "media" -> "Media session"
            else -> "Activity session"
        }
        val appDescription = applicationId
            ?.substringAfterLast(':')
            ?.takeIf { it.isNotBlank() }
            ?.let { " Context: $it." }
            ?: ""
        return DayflowLocalDerivedCard(
            title = title,
            summary = "Local visual derivation classified a $category activity with a ${profile.tone}, ${profile.contrast} visual profile.$appDescription Raw pixels were released before event creation.",
            category = category,
            derivationMode = DERIVATION_MODE,
        )
    }

    /**
     * Kept pure so the visual profile can be tested without an Android
     * MediaProjection or emulator. Samples are packed RGBA bytes.
     */
    internal fun profileFromRgba(samples: ByteArray): DayflowVisualProfile {
        if (samples.size < 4) return DayflowVisualProfile("unknown-tone", "unknown-contrast")
        var luminanceTotal = 0L
        var luminanceSquaredTotal = 0L
        var count = 0
        var index = 0
        while (index + 2 < samples.size) {
            val red = samples[index].toInt() and 0xff
            val green = samples[index + 1].toInt() and 0xff
            val blue = samples[index + 2].toInt() and 0xff
            val luminance = (red * 299 + green * 587 + blue * 114) / 1_000
            luminanceTotal += luminance
            luminanceSquaredTotal += luminance.toLong() * luminance
            count += 1
            index += 4
        }
        if (count == 0) return DayflowVisualProfile("unknown-tone", "unknown-contrast")
        val average = luminanceTotal / count
        val variance = max(0L, luminanceSquaredTotal / count - average * average)
        val tone = when {
            average < 72 -> "dark"
            average > 184 -> "bright"
            else -> "balanced"
        }
        val contrast = when {
            variance > 2_800 -> "high-contrast"
            variance < 500 -> "low-contrast"
            else -> "moderate-contrast"
        }
        return DayflowVisualProfile(tone, contrast)
    }

    private fun profile(image: Image): DayflowVisualProfile {
        val plane = image.planes.firstOrNull()
            ?: return DayflowVisualProfile("unknown-tone", "unknown-contrast")
        val buffer = plane.buffer.duplicate()
        val pixelStride = max(plane.pixelStride, 1)
        val rowStride = max(plane.rowStride, pixelStride)
        val step = max(1, max(image.width, image.height) / 24)
        val samples = ByteArray(min(256, max(1, (image.width / step) * (image.height / step)) * 4))
        var sampleIndex = 0
        var y = 0
        while (y < image.height && sampleIndex + 3 < samples.size) {
            var x = 0
            while (x < image.width && sampleIndex + 3 < samples.size) {
                val offset = y * rowStride + x * pixelStride
                if (offset + 2 < buffer.limit()) {
                    samples[sampleIndex] = buffer.get(offset)
                    samples[sampleIndex + 1] = buffer.get(offset + 1)
                    samples[sampleIndex + 2] = buffer.get(offset + 2)
                    samples[sampleIndex + 3] = 0xff.toByte()
                    sampleIndex += 4
                }
                x += step
            }
            y += step
        }
        return profileFromRgba(samples.copyOf(sampleIndex))
    }

    private fun categoryFor(applicationId: String?): String {
        val normalized = applicationId.orEmpty().lowercase()
        return when {
            listOf("android", "studio", "code", "devenv", "idea", "rider", "terminal", "shell")
                .any(normalized::contains) -> "focus"
            listOf("slack", "teams", "zoom", "meet", "discord", "mail", "gmail")
                .any(normalized::contains) -> "communication"
            listOf("chrome", "firefox", "edge", "browser", "brave")
                .any(normalized::contains) -> "research"
            listOf("youtube", "spotify", "vlc", "music", "video")
                .any(normalized::contains) -> "media"
            else -> "activity"
        }
    }
}
