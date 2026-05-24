package com.casttv.androidtv.crypto

import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * AES-GCM encryption matching the Swift CryptoKit implementation.
 *
 * Wire format: nonce (12 bytes) + ciphertext + GCM tag (16 bytes)
 * This matches AES.GCM.SealedBox.combined in Swift.
 */
object Encryption {
    private const val NONCE_LEN = 12
    private const val TAG_LEN_BITS = 128 // 16 bytes

    fun generateKey(): ByteArray {
        val kg = KeyGenerator.getInstance("AES")
        kg.init(256)
        return kg.generateKey().encoded
    }

    /** Encrypt plaintext. Returns nonce (12) + ciphertext+tag. */
    fun encrypt(
        plaintext: ByteArray,
        key: ByteArray,
    ): ByteArray {
        val nonce = ByteArray(NONCE_LEN).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_LEN_BITS, nonce))
        val ciphertextAndTag = cipher.doFinal(plaintext)
        return nonce + ciphertextAndTag
    }

    /** Decrypt combined (nonce + ciphertext+tag) produced by encrypt(). */
    fun decrypt(
        combined: ByteArray,
        key: ByteArray,
    ): ByteArray {
        val nonce = combined.sliceArray(0 until NONCE_LEN)
        val ciphertextAndTag = combined.sliceArray(NONCE_LEN until combined.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_LEN_BITS, nonce))
        return cipher.doFinal(ciphertextAndTag)
    }

    /** Encode key as base64url (no padding) — matches Swift's base64URLEncoded(). */
    fun keyToBase64Url(key: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(key)

    /** Decode base64url key. */
    fun keyFromBase64Url(encoded: String): ByteArray = Base64.getUrlDecoder().decode(encoded)

    /** Encode encrypted payload as standard base64 for WebSocket transport. */
    fun encryptedToBase64(data: ByteArray): String = Base64.getEncoder().encodeToString(data)

    /** Decode base64 WebSocket payload. */
    fun base64ToBytes(encoded: String): ByteArray = Base64.getDecoder().decode(encoded)
}
