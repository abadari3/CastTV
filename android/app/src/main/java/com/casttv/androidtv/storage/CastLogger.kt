package com.casttv.androidtv.storage

import android.content.Context
import android.util.Log
import com.casttv.androidtv.network.LogMessage
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

private const val TAG = "CastTV.Logger"
private const val MAX_ENTRIES = 5000
private const val MAX_FILE_BYTES = 1_000_000 // 1 MB

object CastLogger {
    data class Entry(val timestamp: Date, val level: String, val message: String)

    private val lock = ReentrantLock()
    private val entries = ArrayDeque<Entry>()
    private var logFile: File? = null
    private var cachedPreviousEntries: List<LogMessage>? = null
    val sessionStart: Date = Date()

    /** Called for each new log entry — wire this up to the WebSocket. Thread-safe. */
    var onNewEntry: ((LogMessage) -> Unit)?
        get() = lock.withLock { _onNewEntry }
        set(value) {
            lock.withLock { _onNewEntry = value }
        }
    private var _onNewEntry: ((LogMessage) -> Unit)? = null

    fun init(context: Context) {
        val cacheDir = context.cacheDir
        val file = File(cacheDir, "casttv.log")

        if (file.exists() && file.length() > MAX_FILE_BYTES) {
            val old = File(cacheDir, "casttv.log.old")
            old.delete()
            file.renameTo(old)
        }

        logFile = file
    }

    fun info(message: String) = log("info", message)

    fun warning(message: String) = log("warning", message)

    fun error(message: String) = log("error", message)

    fun log(
        level: String,
        message: String,
    ) {
        val entry = Entry(Date(), level, message)

        val callback: ((LogMessage) -> Unit)?
        lock.withLock {
            entries.addLast(entry)
            if (entries.size > MAX_ENTRIES) entries.removeFirst()
            callback = _onNewEntry
        }

        writeToFile(entry)

        when (level) {
            "info" -> Log.i(TAG, message)
            "warning" -> Log.w(TAG, message)
            "error" -> Log.e(TAG, message)
        }

        callback?.invoke(entry.toLogMessage())
    }

    /** Entries from the previous session (parsed once, then cached). */
    fun previousSessionEntries(): List<LogMessage> {
        lock.withLock { cachedPreviousEntries }?.let { return it }

        val file = logFile ?: return emptyList()
        if (!file.exists()) {
            lock.withLock { cachedPreviousEntries = emptyList() }
            return emptyList()
        }

        val result =
            try {
                file.readLines()
                    .filter { it.isNotBlank() }
                    .mapNotNull { line ->
                        try {
                            val obj = JSONObject(line)
                            LogMessage(
                                timestamp = obj.getString("timestamp"),
                                level = obj.getString("level"),
                                message = obj.getString("message"),
                            )
                        } catch (e: Exception) {
                            null
                        }
                    }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to read log file: $e")
                emptyList()
            }

        lock.withLock { cachedPreviousEntries = result }
        return result
    }

    fun clearAll() {
        lock.withLock {
            entries.clear()
            cachedPreviousEntries = null
        }
        try {
            logFile?.delete()
            logFile?.createNewFile()
        } catch (_: Exception) {
        }
    }

    private fun writeToFile(entry: Entry) {
        val file = logFile ?: return
        try {
            val json = "{\"timestamp\":\"${entry.toIso8601()}\",\"level\":\"${entry.level}\",\"message\":${JSONObject.quote(
                entry.message,
            )}}\n"
            file.appendText(json)
        } catch (e: Exception) {
            Log.e(TAG, "File write failed: $e")
        }
    }

    private fun Entry.toLogMessage() =
        LogMessage(
            timestamp = toIso8601(),
            level = level,
            message = message,
        )

    private fun Entry.toIso8601(): String {
        val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        sdf.timeZone = TimeZone.getTimeZone("UTC")
        return sdf.format(timestamp)
    }
}
