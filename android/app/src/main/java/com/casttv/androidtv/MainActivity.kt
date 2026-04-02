package com.casttv.androidtv

import android.content.Intent
import android.graphics.Bitmap
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.lifecycle.lifecycleScope
import com.casttv.androidtv.crypto.Encryption
import com.casttv.androidtv.crypto.QRCodeGenerator
import com.casttv.androidtv.device.CapabilityDetector
import com.casttv.androidtv.network.CastMessage
import com.casttv.androidtv.network.CastWebSocketClient
import com.casttv.androidtv.network.ConnectionState
import com.casttv.androidtv.network.MessageCodec
import com.casttv.androidtv.network.LogsHistoryMessage
import com.casttv.androidtv.network.NsdAdvertiser
import com.casttv.androidtv.network.PlayMessage
import com.casttv.androidtv.player.PlayerActivity
import com.casttv.androidtv.storage.CastLogger
import com.casttv.androidtv.storage.PairingStorage
import com.casttv.androidtv.ui.HomeScreen
import com.casttv.androidtv.ui.darkColorScheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.compose.runtime.*

class MainActivity : ComponentActivity() {

    private lateinit var storage: PairingStorage
    private var wsClient: CastWebSocketClient? = null
    private var nsdAdvertiser: NsdAdvertiser? = null

    private val roomCode = mutableStateOf("")
    private val qrBitmap = mutableStateOf<Bitmap?>(null)
    private val connectionState = mutableStateOf(ConnectionState.DISCONNECTED)
    private val connectedDeviceName = mutableStateOf<String?>(null)
    private val errorMessage = mutableStateOf<String?>(null)
    private val qrString = mutableStateOf("")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        storage = PairingStorage(this)

        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                Surface(modifier = Modifier.fillMaxSize(), color = Color.Black) {
                    HomeScreen(
                        roomCode = roomCode.value,
                        qrBitmap = qrBitmap.value,
                        connectionState = connectionState.value,
                        connectedDeviceName = connectedDeviceName.value,
                        errorMessage = errorMessage.value,
                        qrString = qrString.value
                    )
                }
            }
        }

        CastLogger.init(this)
        CastLogger.info("CastTV starting")
        lifecycleScope.launch { startPairing() }
    }

    override fun onResume() {
        super.onResume()
        val ws = wsClient
        if (ws != null && connectionState.value == ConnectionState.DISCONNECTED) {
            ws.connect()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        nsdAdvertiser?.stop()
        wsClient?.disconnect()
    }

    private suspend fun startPairing() {
        val code = storage.loadRoomCode() ?: run {
            val newCode = generateRoomCode()
            storage.saveRoomCode(newCode)
            newCode
        }
        val key = storage.loadEncryptionKey() ?: run {
            val newKey = Encryption.generateKey()
            storage.saveEncryptionKey(newKey)
            newKey
        }

        val pairingString = QRCodeGenerator.buildPairingString(code, key)
        val bitmap = withContext(Dispatchers.Default) {
            QRCodeGenerator.generate(pairingString, 512)
        }

        roomCode.value = code
        qrString.value = pairingString
        qrBitmap.value = bitmap

        CastLogger.info("Room code: $code")
        startNsdAdvertising(code, key)
        connectWebSocket(code, key)
    }

    private fun connectWebSocket(code: String, key: ByteArray) {
        val ws = CastWebSocketClient(code, key, lifecycleScope)
        wsClient = ws

        lifecycleScope.launch {
            ws.state.collectLatest { state ->
                connectionState.value = state
                when (state) {
                    ConnectionState.CONNECTED -> {
                        CastLogger.info("WebSocket connected")
                        sendCapabilities(ws)
                        CastLogger.onNewEntry = { logMsg ->
                            ws.send(MessageCodec.encode(logMsg))
                        }
                    }
                    ConnectionState.DISCONNECTED -> {
                        CastLogger.warning("WebSocket disconnected")
                        CastLogger.onNewEntry = null
                    }
                    ConnectionState.CONNECTING -> {}
                }
            }
        }

        lifecycleScope.launch {
            ws.messages.collect { msg -> handleMessage(msg) }
        }

        ws.connect()
    }

    private fun sendCapabilities(ws: CastWebSocketClient) {
        val caps = CapabilityDetector.detect(this)
        ws.send(MessageCodec.encode(caps))
        CastLogger.info("Sent capabilities: ${caps.model} ${caps.tvOS} ${caps.display.resolution}")
    }

    private fun handleMessage(msg: CastMessage) {
        when (msg) {
            is CastMessage.Play -> {
                CastLogger.info("Play: ${msg.msg.url}")
                errorMessage.value = null
                launchPlayer(msg.msg)
            }
            is CastMessage.DeviceJoined -> {
                if (msg.role == "iphone") {
                    CastLogger.info("iPhone connected")
                    connectedDeviceName.value = "iPhone"
                    wsClient?.let { ws ->
                        sendCapabilities(ws)
                        sendLogsHistory(ws)
                    }
                }
            }
            is CastMessage.DeviceLeft -> {
                if (msg.role == "iphone") {
                    CastLogger.info("iPhone disconnected")
                    connectedDeviceName.value = null
                }
            }
            is CastMessage.ClearLogs -> {
                CastLogger.clearAll()
                CastLogger.info("Logs cleared by iPhone")
            }
            else -> {}
        }
    }

    private fun sendLogsHistory(ws: CastWebSocketClient) {
        val previous = CastLogger.previousSessionEntries()
        if (previous.isNotEmpty()) {
            val sdf = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", java.util.Locale.US)
            sdf.timeZone = java.util.TimeZone.getTimeZone("UTC")
            val history = LogsHistoryMessage(
                session = sdf.format(CastLogger.sessionStart),
                entries = previous
            )
            ws.send(MessageCodec.encode(history))
            CastLogger.info("Sent ${previous.size} previous session log entries")
        }
    }

    private fun launchPlayer(play: PlayMessage) {
        val intent = Intent(this, PlayerActivity::class.java).apply {
            putExtra(PlayerActivity.EXTRA_URL, play.url)
            putExtra(PlayerActivity.EXTRA_SUBTITLE_URL, play.subtitleUrl)
            play.tracks?.video?.let { putExtra(PlayerActivity.EXTRA_VIDEO_TRACK, it) }
            play.tracks?.audio?.let { putExtra(PlayerActivity.EXTRA_AUDIO_TRACK, it) }
            play.tracks?.subtitle?.let { putExtra(PlayerActivity.EXTRA_SUBTITLE_TRACK, it) }
        }
        startActivity(intent)
    }

    private fun startNsdAdvertising(code: String, key: ByteArray) {
        val advertiser = NsdAdvertiser(this)
        nsdAdvertiser = advertiser
        advertiser.start(
            roomCode = code,
            keyBase64URL = Encryption.keyToBase64Url(key),
            deviceName = android.os.Build.MODEL
        )
    }

    private fun generateRoomCode(): String {
        val chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return (1..6).map { chars.random() }.joinToString("")
    }
}
