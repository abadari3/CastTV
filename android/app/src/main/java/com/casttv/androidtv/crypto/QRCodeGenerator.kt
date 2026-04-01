package com.casttv.androidtv.crypto

import android.graphics.Bitmap
import android.graphics.Color
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter

/**
 * Generates a QR code Bitmap for the casttv pairing string.
 *
 * Format: casttv:<roomCode>:<base64url-key>
 * Matches QRCodeData.swift encode().
 */
object QRCodeGenerator {

    /** Build the pairing string from room code + raw key bytes. */
    fun buildPairingString(roomCode: String, key: ByteArray): String =
        "casttv:$roomCode:${Encryption.keyToBase64Url(key)}"

    /** Render the pairing string as a square black-on-white Bitmap. */
    fun generate(content: String, sizePx: Int = 512): Bitmap {
        val hints = mapOf(EncodeHintType.MARGIN to 1)
        val bits = QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, sizePx, sizePx, hints)
        val bmp = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
        for (x in 0 until sizePx) {
            for (y in 0 until sizePx) {
                bmp.setPixel(x, y, if (bits[x, y]) Color.BLACK else Color.WHITE)
            }
        }
        return bmp
    }
}
