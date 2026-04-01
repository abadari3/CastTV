package com.casttv.androidtv.storage

import android.content.Context
import android.content.SharedPreferences
import com.casttv.androidtv.crypto.Encryption

/**
 * Persists this Android TV's room code and AES-256 encryption key.
 */
class PairingStorage(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences("com.casttv.androidtv.pairing", Context.MODE_PRIVATE)

    fun saveRoomCode(code: String) = prefs.edit().putString(KEY_ROOM_CODE, code).apply()

    fun loadRoomCode(): String? = prefs.getString(KEY_ROOM_CODE, null)

    fun saveEncryptionKey(key: ByteArray) =
        prefs.edit().putString(KEY_ENCRYPTION_KEY, Encryption.keyToBase64Url(key)).apply()

    fun loadEncryptionKey(): ByteArray? =
        prefs.getString(KEY_ENCRYPTION_KEY, null)?.let { Encryption.keyFromBase64Url(it) }

    fun clear() = prefs.edit().clear().apply()

    companion object {
        private const val KEY_ROOM_CODE = "room_code"
        private const val KEY_ENCRYPTION_KEY = "encryption_key"
    }
}
