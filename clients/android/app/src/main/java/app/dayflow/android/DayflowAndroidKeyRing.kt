package app.dayflow.android

import android.util.Base64
import org.json.JSONObject

/**
 * Android/ChromeOS representation of the locally retained account key
 * versions. The JSON form is passed only to the Rust core; the encrypted
 * document itself is kept in Android Keystore-backed storage.
 */
class DayflowAndroidAccountKeyRing private constructor(
    val activeKeyVersion: UInt,
    private val material: Map<UInt, ByteArray>,
) {
    init {
        require(activeKeyVersion > 0u && material.isNotEmpty())
        require(material.keys.all { it > 0u })
        require(material[activeKeyVersion]?.size == 32)
        require(material.values.all { it.size == 32 })
    }

    fun keyData(version: UInt): ByteArray? = material[version]?.copyOf()

    fun versions(): List<UInt> = material.keys.sorted()

    fun toJson(): String = JSONObject()
        .put("active_key_version", activeKeyVersion.toLong())
        .put("keys", JSONObject().apply {
            material.toSortedMap().forEach { (version, key) ->
                put(version.toString(), Base64.encodeToString(key, Base64.NO_WRAP))
            }
        })
        .toString()

    fun adding(key: ByteArray, version: UInt, active: Boolean = false): DayflowAndroidAccountKeyRing {
        require(key.size == 32)
        val updated = material.mapValues { (_, value) -> value.copyOf() }.toMutableMap()
        updated[version] = key.copyOf()
        return fromKeys(if (active) version else activeKeyVersion, updated)
    }

    companion object {
        fun fromRootKey(rootKey: ByteArray): DayflowAndroidAccountKeyRing =
            fromKeys(1u, mapOf(1u to rootKey))

        fun fromKeysForSync(
            active: UInt,
            rootKey: ByteArray,
        ): DayflowAndroidAccountKeyRing = fromKeys(active, mapOf(active to rootKey))

        fun fromJson(value: String): DayflowAndroidAccountKeyRing {
            val json = JSONObject(value)
            val active = json.getLong("active_key_version").toUInt()
            val keysJson = json.getJSONObject("keys")
            val keys = mutableMapOf<UInt, ByteArray>()
            keysJson.keys().forEach { encodedVersion ->
                val version = encodedVersion.toUIntOrNull()
                    ?: error("The account key-ring version is invalid")
                keys[version] = Base64.decode(keysJson.getString(encodedVersion), Base64.DEFAULT)
            }
            return fromKeys(active, keys)
        }

        private fun fromKeys(
            active: UInt,
            keys: Map<UInt, ByteArray>,
        ): DayflowAndroidAccountKeyRing = DayflowAndroidAccountKeyRing(
            activeKeyVersion = active,
            material = keys.mapValues { (_, value) -> value.copyOf() },
        )
    }
}
