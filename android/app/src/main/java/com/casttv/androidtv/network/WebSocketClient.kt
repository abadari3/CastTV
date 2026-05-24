package com.casttv.androidtv.network

import android.util.Log
import com.casttv.androidtv.crypto.Encryption
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.TimeUnit

private const val TAG = "CastTV.WS"
const val SERVER_BASE_URL = "wss://cast.anandabadari.com"

enum class ConnectionState { DISCONNECTED, CONNECTING, CONNECTED }

/**
 * WebSocket client for the CastTV relay server.
 * Connects as role=androidtv, handles AES-GCM encrypted messages.
 */
class CastWebSocketClient(
    private val roomCode: String,
    private val encryptionKey: ByteArray,
    private val scope: CoroutineScope,
) {
    private val client =
        OkHttpClient.Builder()
            .pingInterval(20, TimeUnit.SECONDS)
            .build()

    private val _state = MutableStateFlow(ConnectionState.DISCONNECTED)
    val state: StateFlow<ConnectionState> = _state

    private val _messages = MutableSharedFlow<CastMessage>(extraBufferCapacity = 64)
    val messages: SharedFlow<CastMessage> = _messages

    private var socket: WebSocket? = null
    private var shouldReconnect = false
    private var reconnectJob: Job? = null

    fun connect() {
        if (_state.value != ConnectionState.DISCONNECTED) return
        shouldReconnect = true
        openSocket()
    }

    fun disconnect() {
        shouldReconnect = false
        reconnectJob?.cancel()
        socket?.close(1000, "Going away")
        socket = null
        _state.value = ConnectionState.DISCONNECTED
    }

    /** Send an encrypted message. */
    fun send(json: String) {
        val ws = socket ?: return
        try {
            val encrypted = Encryption.encrypt(json.toByteArray(Charsets.UTF_8), encryptionKey)
            ws.send(Encryption.encryptedToBase64(encrypted))
        } catch (e: Exception) {
            Log.e(TAG, "Send failed: $e")
        }
    }

    private fun openSocket() {
        _state.value = ConnectionState.CONNECTING
        val url = "$SERVER_BASE_URL/room/$roomCode/ws?role=androidtv"
        val request = Request.Builder().url(url).build()
        socket = client.newWebSocket(request, Listener())
        Log.i(TAG, "Connecting to $url")
    }

    private fun scheduleReconnect() {
        reconnectJob =
            scope.launch(Dispatchers.IO) {
                delay(2000)
                if (shouldReconnect && _state.value == ConnectionState.DISCONNECTED) {
                    openSocket()
                }
            }
    }

    private inner class Listener : WebSocketListener() {
        override fun onOpen(
            webSocket: WebSocket,
            response: Response,
        ) {
            Log.i(TAG, "Connected")
            _state.value = ConnectionState.CONNECTED
        }

        override fun onMessage(
            webSocket: WebSocket,
            text: String,
        ) {
            val json = tryDecrypt(text) ?: text
            val msg = MessageCodec.decode(json)
            scope.launch { _messages.emit(msg) }
        }

        override fun onFailure(
            webSocket: WebSocket,
            t: Throwable,
            response: Response?,
        ) {
            Log.e(TAG, "WebSocket failure: $t")
            socket = null
            _state.value = ConnectionState.DISCONNECTED
            if (shouldReconnect) scheduleReconnect()
        }

        override fun onClosed(
            webSocket: WebSocket,
            code: Int,
            reason: String,
        ) {
            Log.i(TAG, "Closed: $code $reason")
            socket = null
            _state.value = ConnectionState.DISCONNECTED
            if (shouldReconnect) scheduleReconnect()
        }

        private fun tryDecrypt(base64Text: String): String? {
            return try {
                val encrypted = Encryption.base64ToBytes(base64Text)
                val plaintext = Encryption.decrypt(encrypted, encryptionKey)
                plaintext.toString(Charsets.UTF_8)
            } catch (e: Exception) {
                null
            }
        }
    }
}
