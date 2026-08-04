package app.dayflow.android

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.io.Closeable
import java.security.MessageDigest

enum class DayflowAndroidSyncHealthState(val rawValue: String) {
    UNKNOWN("unknown"),
    SYNCED("synced"),
    WAITING_FOR_APPROVAL("waiting_for_approval"),
    FAILED("failed");

    companion object {
        fun fromRawValue(value: String?): DayflowAndroidSyncHealthState =
            entries.firstOrNull { it.rawValue == value } ?: UNKNOWN
    }
}

data class DayflowAndroidSyncHealth(
    val lastSyncAtMillis: Long? = null,
    val lastSuccessfulSyncAtMillis: Long? = null,
    val state: DayflowAndroidSyncHealthState = DayflowAndroidSyncHealthState.UNKNOWN,
    val failureCode: String? = null,
) {
    fun summary(pendingEventCount: Int, nowMillis: Long = System.currentTimeMillis()): String {
        val parts = mutableListOf<String>()
        when (state) {
            DayflowAndroidSyncHealthState.SYNCED -> {
                val syncedAt = lastSuccessfulSyncAtMillis ?: lastSyncAtMillis
                parts += if (syncedAt == null) "Synced locally" else "Last synced ${relativeTime(syncedAt, nowMillis)}"
            }
            DayflowAndroidSyncHealthState.WAITING_FOR_APPROVAL -> parts += "Waiting for device approval"
            DayflowAndroidSyncHealthState.FAILED -> parts += "Last sync failed"
            DayflowAndroidSyncHealthState.UNKNOWN -> parts += "Not synced yet"
        }
        if (pendingEventCount > 0) {
            parts += "$pendingEventCount encrypted event${if (pendingEventCount == 1) "" else "s"} queued"
        } else if (state == DayflowAndroidSyncHealthState.SYNCED) {
            parts += "No events queued"
        }
        if (state == DayflowAndroidSyncHealthState.FAILED && !failureCode.isNullOrBlank()) {
            parts += "Reason: ${failureCode.replace('_', ' ')}"
        }
        return parts.joinToString(" · ")
    }

    private fun relativeTime(timestampMillis: Long, nowMillis: Long): String {
        val elapsedSeconds = ((nowMillis - timestampMillis).coerceAtLeast(0L)) / 1_000L
        return when {
            elapsedSeconds < 60L -> "just now"
            elapsedSeconds < 3_600L -> "${elapsedSeconds / 60L}m ago"
            elapsedSeconds < 86_400L -> "${elapsedSeconds / 3_600L}h ago"
            else -> "${elapsedSeconds / 86_400L}d ago"
        }
    }
}

/**
 * Device-local SQLite outbox. The table stores only Rust-produced encrypted
 * envelope fields and non-sensitive sync metadata. Projections are rebuilt
 * from the envelopes in memory; plaintext journal, timeline, and capture data
 * are never persisted in this database.
 */
class DayflowLocalSyncStore(
    context: Context,
    accountId: String,
) : Closeable {
    private val helper = Helper(context, "dayflow-sync-${stableName(accountId)}.db")
    private val database: SQLiteDatabase = helper.writableDatabase

    fun enqueue(envelope: DayflowEventEnvelope) {
        validate(envelope)
        // Capture and UI writes can overlap with a foreground sync. Keep the
        // immutable-ID preflight and INSERT in one transaction so a racing
        // envelope cannot pass the check and then be silently discarded by
        // CONFLICT_IGNORE.
        database.beginTransaction()
        try {
            rejectConflictingEnvelope(envelope)
            database.insertWithOnConflict(
                "event_envelopes",
                null,
                values(envelope, "pending"),
                SQLiteDatabase.CONFLICT_IGNORE,
            )
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
    }

    fun pending(limit: Int = 100): List<DayflowEventEnvelope> = query(
        "state = ?",
        arrayOf("pending"),
        limit,
    )

    fun pendingCount(): Int = database.rawQuery(
        "SELECT COUNT(*) FROM event_envelopes WHERE state = 'pending'",
        null,
    ).use { cursor ->
        if (cursor.moveToFirst()) cursor.getInt(0) else 0
    }

    fun acknowledge(eventIds: List<String>): Int {
        var count = 0
        database.beginTransaction()
        try {
            eventIds.forEach { id ->
                count += database.update(
                    "event_envelopes",
                    ContentValues().apply { put("state", "acknowledged") },
                    "event_id = ?",
                    arrayOf(id),
                )
            }
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
        return count
    }

    fun merge(envelopes: List<DayflowEventEnvelope>): Int {
        var count = 0
        database.beginTransaction()
        try {
            var maximumRemoteClock = 0uL
            envelopes.forEach { envelope ->
                validate(envelope)
                rejectConflictingEnvelope(envelope)
                if (envelope.logicalClock > maximumRemoteClock) {
                    maximumRemoteClock = envelope.logicalClock
                }
                count += database.insertWithOnConflict(
                    "event_envelopes",
                    null,
                    values(envelope, "acknowledged"),
                    SQLiteDatabase.CONFLICT_IGNORE,
                ).let { if (it == -1L) 0 else 1 }
            }
            // A device-local Lamport clock must move beyond accepted remote
            // events before the next local write. Keep this update inside the
            // merge transaction so conflicts roll it back as well.
            if (maximumRemoteClock > 0uL) {
                val current = metadata("logical_clock")?.toULongOrNull() ?: 0uL
                if (current < maximumRemoteClock) {
                    setMetadata("logical_clock", maximumRemoteClock.toString())
                }
            }
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
        return count
    }

    fun all(): List<DayflowEventEnvelope> = query(null, null, null)

    fun find(eventId: String): DayflowEventEnvelope? = database.query(
        "event_envelopes",
        COLUMNS,
        "event_id = ?",
        arrayOf(eventId),
        null,
        null,
        null,
        "1",
    ).use { cursor ->
        if (!cursor.moveToFirst()) return@use null
        DayflowEventEnvelope(
            eventId = cursor.getString(0),
            deviceId = cursor.getString(1),
            logicalClock = cursor.getLong(2).toULong(),
            schemaVersion = cursor.getInt(3).toUShort(),
            keyVersion = cursor.getLong(4).toUInt(),
            nonce = cursor.getString(5),
            ciphertext = cursor.getString(6),
        )
    }

    fun cursor(): String? = metadata("relay_cursor")

    fun setCursor(value: String) = setMetadata("relay_cursor", value)

    /** Notification hints have a cursor separate from encrypted event replay. */
    fun notificationCursor(): String? = metadata("notification_cursor")

    fun setNotificationCursor(value: String) {
        require(value.isNotBlank()) { "Notification cursor cannot be empty" }
        setMetadata("notification_cursor", value)
    }

    fun linkedAccountId(): String? = metadata("linked_account_id")

    fun setLinkedAccountId(value: String) {
        require(value.isNotBlank()) { "Linked account ID cannot be empty" }
        setMetadata("linked_account_id", value)
    }

    fun syncHealth(): DayflowAndroidSyncHealth = DayflowAndroidSyncHealth(
        lastSyncAtMillis = metadata("last_sync_at")?.toLongOrNull(),
        lastSuccessfulSyncAtMillis = metadata("last_successful_sync_at")?.toLongOrNull(),
        state = DayflowAndroidSyncHealthState.fromRawValue(metadata("last_sync_state")),
        failureCode = metadata("last_sync_failure"),
    )

    /** Persists only bounded sync metadata; event content never enters this table. */
    fun recordSyncHealth(
        state: DayflowAndroidSyncHealthState,
        failureCode: String? = null,
        atMillis: Long = System.currentTimeMillis(),
    ) {
        val timestamp = atMillis.toString()
        database.beginTransaction()
        try {
            setMetadata("last_sync_at", timestamp)
            setMetadata("last_sync_state", state.rawValue)
            when (state) {
                DayflowAndroidSyncHealthState.SYNCED -> {
                    setMetadata("last_successful_sync_at", timestamp)
                    deleteMetadata("last_sync_failure")
                }
                DayflowAndroidSyncHealthState.FAILED -> setMetadata(
                    "last_sync_failure",
                    boundedFailureCode(failureCode),
                )
                DayflowAndroidSyncHealthState.UNKNOWN,
                DayflowAndroidSyncHealthState.WAITING_FOR_APPROVAL -> Unit
            }
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
    }

    /**
     * Seeds the destination workspace clock after local-workspace linking.
     * Both databases use the same physical device ID, so a destination clock
     * that starts at zero could reuse logical-clock values already present in
     * the signed-out workspace after sign-in.
     */
    fun ensureLogicalClockAtLeast(value: ULong) {
        val maximum = DayflowEventEnvelope.MAX_LOGICAL_CLOCK.toULong()
        require(value <= maximum) { "The local logical clock exceeds the JSON relay's safe integer range" }
        database.beginTransaction()
        try {
            val current = metadata("logical_clock")?.toULongOrNull() ?: 0uL
            if (current < value) setMetadata("logical_clock", value.toString())
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
    }

    fun nextLogicalClock(): ULong {
        database.beginTransaction()
        try {
            val current = metadata("logical_clock")?.toULongOrNull() ?: 0uL
            require(current < DayflowEventEnvelope.MAX_LOGICAL_CLOCK.toULong()) { "The local logical clock is exhausted" }
            val next = current + 1uL
            setMetadata("logical_clock", next.toString())
            database.setTransactionSuccessful()
            return next
        } finally {
            database.endTransaction()
        }
    }

    override fun close() {
        helper.close()
    }

    private fun query(selection: String?, args: Array<String>?, limit: Int?): List<DayflowEventEnvelope> {
        val rows = mutableListOf<DayflowEventEnvelope>()
        val sqlLimit = limit?.coerceIn(1, 1000)?.toString()
        database.query(
            "event_envelopes",
            COLUMNS,
            selection,
            args,
            null,
            null,
            "logical_clock ASC, device_id ASC, event_id ASC",
            sqlLimit,
        ).use { cursor ->
            while (cursor.moveToNext()) {
                rows += DayflowEventEnvelope(
                    eventId = cursor.getString(0),
                    deviceId = cursor.getString(1),
                    logicalClock = cursor.getLong(2).toULong(),
                    schemaVersion = cursor.getInt(3).toUShort(),
                    keyVersion = cursor.getLong(4).toUInt(),
                    nonce = cursor.getString(5),
                    ciphertext = cursor.getString(6),
                )
            }
        }
        return rows
    }

    private fun values(envelope: DayflowEventEnvelope, state: String) = ContentValues().apply {
        put("event_id", envelope.eventId)
        put("device_id", envelope.deviceId)
        put("logical_clock", envelope.logicalClock.toString())
        put("schema_version", envelope.schemaVersion.toInt())
        put("key_version", envelope.keyVersion.toLong())
        put("nonce", envelope.nonce)
        put("ciphertext", envelope.ciphertext)
        put("state", state)
    }

    private fun validate(envelope: DayflowEventEnvelope) {
        require(envelope.eventId.isNotBlank() && envelope.deviceId.isNotBlank())
        require(envelope.logicalClock in 1uL..DayflowEventEnvelope.MAX_LOGICAL_CLOCK.toULong())
        require(envelope.schemaVersion.toInt() == DayflowEventEnvelope.CURRENT_SCHEMA_VERSION)
        require(envelope.keyVersion > 0u)
        require(DayflowWireEnvelopeValidation.hasValidEncryptedFieldShape(envelope.nonce, envelope.ciphertext)) {
            "The encrypted event envelope has invalid nonce/ciphertext encoding."
        }
    }

    private fun rejectConflictingEnvelope(envelope: DayflowEventEnvelope) {
        database.query(
            "event_envelopes",
            COLUMNS,
            "event_id = ?",
            arrayOf(envelope.eventId),
            null,
            null,
            null,
            "1",
        ).use { cursor ->
            if (!cursor.moveToFirst()) return
            val existing = DayflowEventEnvelope(
                eventId = cursor.getString(0),
                deviceId = cursor.getString(1),
                logicalClock = cursor.getLong(2).toULong(),
                schemaVersion = cursor.getInt(3).toUShort(),
                keyVersion = cursor.getLong(4).toUInt(),
                nonce = cursor.getString(5),
                ciphertext = cursor.getString(6),
            )
            require(existing == envelope) {
                "Event ID '${envelope.eventId}' already exists with a different envelope."
            }
        }
    }

    private fun metadata(key: String): String? = database.query(
        "sync_metadata",
        arrayOf("value"),
        "key = ?",
        arrayOf(key),
        null,
        null,
        null,
        "1",
    ).use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }

    private fun setMetadata(key: String, value: String) {
        database.insertWithOnConflict(
            "sync_metadata",
            null,
            ContentValues().apply {
                put("key", key)
                put("value", value)
            },
            SQLiteDatabase.CONFLICT_REPLACE,
        )
    }

    private fun deleteMetadata(key: String) {
        database.delete("sync_metadata", "key = ?", arrayOf(key))
    }

    private fun boundedFailureCode(value: String?): String {
        val normalized = value.orEmpty().lowercase().filter {
            it.isLetterOrDigit() || it == '_' || it == '-'
        }.take(48)
        return normalized.ifBlank { "unknown" }
    }

    private class Helper(context: Context, name: String) : SQLiteOpenHelper(context, name, null, 2) {
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL("""
                CREATE TABLE event_envelopes (
                    event_id TEXT PRIMARY KEY NOT NULL,
                    device_id TEXT NOT NULL,
                    logical_clock INTEGER NOT NULL,
                    schema_version INTEGER NOT NULL,
                    key_version INTEGER NOT NULL,
                    nonce TEXT NOT NULL,
                    ciphertext TEXT NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('pending', 'acknowledged'))
                )
            """.trimIndent())
            db.execSQL("CREATE INDEX idx_event_state ON event_envelopes(state, logical_clock)")
            db.execSQL("CREATE TABLE sync_metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
        }

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            if (oldVersion < 2) {
                // Remove the old derived plaintext cache while retaining the
                // encrypted event outbox and its logical clock.
                db.delete("sync_metadata", "key = ?", arrayOf("projection_json"))
            }
        }
    }

    private companion object {
        val COLUMNS = arrayOf(
            "event_id", "device_id", "logical_clock", "schema_version",
            "key_version", "nonce", "ciphertext",
        )

        fun stableName(value: String): String = MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }
}
