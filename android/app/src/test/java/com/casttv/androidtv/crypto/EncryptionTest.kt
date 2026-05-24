package com.casttv.androidtv.crypto

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class EncryptionTest {
    @Test
    fun roundTripRecoversPlaintext() {
        val key = Encryption.generateKey()
        val plaintext = "Hello, CastTV!".toByteArray()
        val encrypted = Encryption.encrypt(plaintext, key)
        val decrypted = Encryption.decrypt(encrypted, key)
        assertArrayEquals(plaintext, decrypted)
    }

    @Test
    fun generatedKeyIs32Bytes() {
        val key = Encryption.generateKey()
        assertEquals(32, key.size)
    }

    @Test
    fun nonceDiffersAcrossCallsWithSameKey() {
        val key = Encryption.generateKey()
        val plaintext = "same".toByteArray()
        val a = Encryption.encrypt(plaintext, key)
        val b = Encryption.encrypt(plaintext, key)
        assertNotEquals(a.toList(), b.toList())
    }

    @Test(expected = javax.crypto.AEADBadTagException::class)
    fun decryptWithWrongKeyThrows() {
        val k1 = Encryption.generateKey()
        val k2 = Encryption.generateKey()
        val encrypted = Encryption.encrypt("data".toByteArray(), k1)
        Encryption.decrypt(encrypted, k2)
    }

    @Test
    fun emptyPlaintextRoundTrips() {
        val key = Encryption.generateKey()
        val encrypted = Encryption.encrypt(ByteArray(0), key)
        val decrypted = Encryption.decrypt(encrypted, key)
        assertEquals(0, decrypted.size)
    }

    @Test
    fun keyBase64UrlRoundTrip() {
        val key = Encryption.generateKey()
        val encoded = Encryption.keyToBase64Url(key)
        // Base64url: no padding (=), only A-Z a-z 0-9 - _
        assertEquals(43, encoded.length) // 32 bytes -> 43 chars unpadded
        assert(!encoded.contains('=')) { "URL-safe encoding must not contain padding" }
        assert(!encoded.contains('+')) { "URL-safe encoding must not contain +" }
        assert(!encoded.contains('/')) { "URL-safe encoding must not contain /" }
        val decoded = Encryption.keyFromBase64Url(encoded)
        assertArrayEquals(key, decoded)
    }

    @Test
    fun keyBase64UrlMatchesKnownFixture() {
        // 32-byte key of all zeros -> 43 zero-bytes encoded as 'A' * 43
        val zeros = ByteArray(32)
        assertEquals("A".repeat(43), Encryption.keyToBase64Url(zeros))
        assertArrayEquals(zeros, Encryption.keyFromBase64Url("A".repeat(43)))
    }

    @Test
    fun encryptedBase64RoundTrip() {
        val key = Encryption.generateKey()
        val payload = "WebSocket frame".toByteArray()
        val encrypted = Encryption.encrypt(payload, key)
        val encoded = Encryption.encryptedToBase64(encrypted)
        val decoded = Encryption.base64ToBytes(encoded)
        assertArrayEquals(encrypted, decoded)
        assertArrayEquals(payload, Encryption.decrypt(decoded, key))
    }
}
