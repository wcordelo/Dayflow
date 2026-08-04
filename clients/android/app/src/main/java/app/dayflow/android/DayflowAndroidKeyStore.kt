package app.dayflow.android

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.nio.ByteBuffer
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Android Keystore-backed custody for account and device key bytes. */
class DayflowAndroidKeyStore(context: Context) {
    private val preferences: SharedPreferences = context.getSharedPreferences(
        "dayflow_secure_multidevice",
        Context.MODE_PRIVATE,
    )
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    fun load(accountId: String, name: String): ByteArray? = preferences.getString(key(accountId, name), null)?.let {
        decrypt(alias(accountId, name), Base64.decode(it, Base64.NO_WRAP))
    }

    fun store(accountId: String, name: String, value: ByteArray) {
        val encrypted = encrypt(alias(accountId, name), value)
        check(
            preferences.edit()
                .putString(key(accountId, name), Base64.encodeToString(encrypted, Base64.NO_WRAP))
                .commit(),
        ) { "Android secure storage could not commit $name." }
    }

    fun loadText(accountId: String, name: String): String? =
        load(accountId, name)?.toString(Charsets.UTF_8)

    fun storeText(accountId: String, name: String, value: String) {
        store(accountId, name, value.toByteArray(Charsets.UTF_8))
    }

    fun accountKeyRing(accountId: String): DayflowAndroidAccountKeyRing? {
        val stored = loadText(accountId, "account-key-ring-v1")
        if (!stored.isNullOrBlank()) {
            return runCatching { DayflowAndroidAccountKeyRing.fromJson(stored) }
                .getOrElse { error("The stored Dayflow account key-ring is invalid") }
        }
        return load(accountId, "root-key-v1")?.let { root ->
            runCatching { DayflowAndroidAccountKeyRing.fromRootKey(root) }
                .getOrElse { error("The stored Dayflow account root key is invalid") }
        }
    }

    fun storeAccountKeyRing(accountId: String, keyRing: DayflowAndroidAccountKeyRing) {
        storeText(accountId, "account-key-ring-v1", keyRing.toJson())
        keyRing.keyData(1u)?.let { store(accountId, "root-key-v1", it) }
    }

    /** True after this device has received an explicitly admitted account key. */
    fun hasAccountKeyAdmission(accountId: String): Boolean =
        load(accountId, "account-key-admitted-v1")?.contentEquals(byteArrayOf(1)) == true

    fun markAccountKeyAdmitted(accountId: String) {
        store(accountId, "account-key-admitted-v1", byteArrayOf(1))
    }

    fun pendingAccountKeyRing(accountId: String): DayflowAndroidAccountKeyRing? {
        val stored = loadText(accountId, "account-key-ring-pending-v1")
        return if (stored.isNullOrBlank()) null else runCatching {
            DayflowAndroidAccountKeyRing.fromJson(stored)
        }.getOrElse { error("The stored pending Dayflow account key-ring is invalid") }
    }

    fun storePendingAccountKeyRing(accountId: String, keyRing: DayflowAndroidAccountKeyRing) {
        storeText(accountId, "account-key-ring-pending-v1", keyRing.toJson())
    }

    fun clearPendingAccountKeyRing(accountId: String) {
        delete(accountId, "account-key-ring-pending-v1")
    }

    fun delete(accountId: String, name: String) {
        check(preferences.edit().remove(key(accountId, name)).commit()) {
            "Android secure storage could not delete $name."
        }
        if (keyStore.containsAlias(alias(accountId, name))) {
            keyStore.deleteEntry(alias(accountId, name))
        }
    }

    fun deviceMaterial(accountId: String): DeviceKeyMaterial? {
        val privateKey = load(accountId, "device-private-v1") ?: return null
        val publicKey = load(accountId, "device-public-v1") ?: return null
        return if (privateKey.size == 32 && publicKey.size == 32) DeviceKeyMaterial(privateKey, publicKey) else null
    }

    fun signingMaterial(accountId: String): DeviceKeyMaterial? {
        val privateKey = load(accountId, "signing-private-v1") ?: return null
        val publicKey = load(accountId, "signing-public-v1") ?: return null
        return if (privateKey.size == 32 && publicKey.size == 32) DeviceKeyMaterial(privateKey, publicKey) else null
    }

    private fun encrypt(alias: String, value: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey(alias))
        val encrypted = cipher.doFinal(value)
        return ByteBuffer.allocate(4 + cipher.iv.size + encrypted.size)
            .putInt(cipher.iv.size)
            .put(cipher.iv)
            .put(encrypted)
            .array()
    }

    private fun decrypt(alias: String, value: ByteArray): ByteArray {
        val buffer = ByteBuffer.wrap(value)
        val iv = ByteArray(buffer.int)
        buffer.get(iv)
        val encrypted = ByteArray(buffer.remaining())
        buffer.get(encrypted)
        return Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, secretKey(alias), GCMParameterSpec(128, iv))
            doFinal(encrypted)
        }
    }

    private fun secretKey(alias: String): SecretKey {
        if (!keyStore.containsAlias(alias)) {
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            generator.init(
                KeyGenParameterSpec.Builder(
                    alias,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setUserAuthenticationRequired(false)
                    .build(),
            )
            generator.generateKey()
        }
        return (keyStore.getEntry(alias, null) as KeyStore.SecretKeyEntry).secretKey
    }

    private fun alias(accountId: String, name: String): String {
        val accountDigest = MessageDigest.getInstance("SHA-256")
            .digest(accountId.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        return "dayflow.$accountDigest.$name"
    }

    private fun key(accountId: String, name: String) = "$accountId:$name"
}
