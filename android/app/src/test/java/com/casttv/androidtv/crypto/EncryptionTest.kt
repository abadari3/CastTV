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
}
