package com.casttv.androidtv.player

import com.casttv.androidtv.storage.CastLogger

import android.content.ComponentCallbacks2
import android.os.Bundle
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.PlayerView

/**
 * Fullscreen ExoPlayer activity.
 *
 * ExoPlayer natively handles MKV, HEVC, DTS, TrueHD, EAC3, FLAC, Opus, SRT, ASS, PGS —
 * no remux/transcode pipeline needed (unlike the Apple TV implementation).
 */
class PlayerActivity : ComponentActivity() {

    private var player: ExoPlayer? = null
    private lateinit var playerView: PlayerView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Keep screen on during playback
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // Fullscreen
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_FULLSCREEN or
            View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
        )

        playerView = PlayerView(this)
        playerView.useController = true
        playerView.controllerAutoShow = true
        playerView.controllerShowTimeoutMs = 3000
        setContentView(playerView)

        val url = intent.getStringExtra(EXTRA_URL) ?: run {
            CastLogger.error("PlayerActivity: no URL in intent")
            finish()
            return
        }

        CastLogger.info("Playing: $url")
        initPlayer(url)
    }

    private fun initPlayer(url: String) {
        val audioAttributes = AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
            .build()

        val loadControl = androidx.media3.exoplayer.DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                20_000,   // min buffer 20s (keep buffer consistently filled)
                20_000,   // max buffer 20s (same as min — drip-feeding for stable playback)
                1_000,    // 1s buffer before first frame (faster start)
                1_000     // 1s buffer after rebuffer (faster recovery)
            )
            .setTargetBufferBytes(32 * 1024 * 1024) // 32 MB cap
            .build()

        // 30s connect/read timeouts — prevents hangs on slow or interrupted connections
        val httpDataSourceFactory = DefaultHttpDataSource.Factory()
            .setConnectTimeoutMs(30_000)
            .setReadTimeoutMs(30_000)
            .setAllowCrossProtocolRedirects(true)

        // Fall back to software decoders if hardware decoders are unavailable
        val renderersFactory = DefaultRenderersFactory(this)
            .setEnableDecoderFallback(true)

        val exoPlayer = ExoPlayer.Builder(this, renderersFactory)
            .setAudioAttributes(audioAttributes, /* handleAudioFocus= */ true)
            .setLoadControl(loadControl)
            .setMediaSourceFactory(DefaultMediaSourceFactory(httpDataSourceFactory))
            .setSeekForwardIncrementMs(10_000)
            .setSeekBackIncrementMs(10_000)
            .build()
        player = exoPlayer
        playerView.player = exoPlayer

        // Build media item — ExoPlayer auto-detects HLS, DASH, progressive
        val mediaItem = MediaItem.Builder()
            .setUri(url)
            .apply {
                // External subtitle track if provided
                intent.getStringExtra(EXTRA_SUBTITLE_URL)?.let { subUrl ->
                    setSubtitleConfigurations(
                        listOf(
                            MediaItem.SubtitleConfiguration.Builder(android.net.Uri.parse(subUrl))
                                .setMimeType(androidx.media3.common.MimeTypes.TEXT_VTT)
                                .build()
                        )
                    )
                }
            }
            .build()

        exoPlayer.setMediaItem(mediaItem)
        exoPlayer.prepare()
        exoPlayer.playWhenReady = true

        // Track selection hints from the iPhone
        val videoTrack = intent.getIntExtra(EXTRA_VIDEO_TRACK, -1)
        val audioTrack = intent.getIntExtra(EXTRA_AUDIO_TRACK, -1)

        exoPlayer.addListener(object : androidx.media3.common.Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                val stateName = when (playbackState) {
                    androidx.media3.common.Player.STATE_IDLE -> "IDLE"
                    androidx.media3.common.Player.STATE_BUFFERING -> "BUFFERING"
                    androidx.media3.common.Player.STATE_READY -> "READY"
                    androidx.media3.common.Player.STATE_ENDED -> "ENDED"
                    else -> "UNKNOWN"
                }
                CastLogger.info("Player state: $stateName")
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                CastLogger.info(if (isPlaying) "Playback started" else "Playback paused")
            }

            override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                CastLogger.error("Player error: ${error.message} (code ${error.errorCode})")
            }

            override fun onTracksChanged(tracks: androidx.media3.common.Tracks) {
                val videoGroups = tracks.groups.count { it.type == androidx.media3.common.C.TRACK_TYPE_VIDEO }
                val audioGroups = tracks.groups.count { it.type == androidx.media3.common.C.TRACK_TYPE_AUDIO }
                val subGroups   = tracks.groups.count { it.type == androidx.media3.common.C.TRACK_TYPE_TEXT }
                CastLogger.info("Tracks loaded: $videoGroups video, $audioGroups audio, $subGroups subtitle groups")
            }
        })
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        val p = player ?: return super.onKeyDown(keyCode, event)
        return when (keyCode) {
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> {
                if (p.isPlaying) p.pause() else p.play()
                playerView.showController()
                true
            }
            KeyEvent.KEYCODE_MEDIA_PLAY -> { p.play(); playerView.showController(); true }
            KeyEvent.KEYCODE_MEDIA_PAUSE -> { p.pause(); playerView.showController(); true }
            KeyEvent.KEYCODE_MEDIA_STOP -> { finish(); true }
            KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> {
                val ms = seekIncrement(event?.repeatCount ?: 0)
                p.seekTo((p.currentPosition + ms).coerceAtMost(p.duration))
                playerView.showController(); true
            }
            KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_MEDIA_REWIND -> {
                val ms = seekIncrement(event?.repeatCount ?: 0)
                p.seekTo((p.currentPosition - ms).coerceAtLeast(0))
                playerView.showController(); true
            }
            KeyEvent.KEYCODE_BACK -> { finish(); true }
            else -> super.onKeyDown(keyCode, event)
        }
    }

    /** Returns seek amount in ms based on how long the key has been held. */
    private fun seekIncrement(repeatCount: Int): Long = when {
        repeatCount < 3  -> 10_000L       // taps: 10s
        repeatCount < 8  -> 30_000L       // short hold: 30s
        repeatCount < 15 -> 60_000L       // medium hold: 1 min
        else             -> 300_000L      // long hold: 5 min
    }

    override fun onPause() {
        super.onPause()
        player?.pause()
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        val label = when (level) {
            ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE -> "RUNNING_MODERATE"
            ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW      -> "RUNNING_LOW"
            ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL -> "RUNNING_CRITICAL"
            ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN        -> "UI_HIDDEN"
            ComponentCallbacks2.TRIM_MEMORY_BACKGROUND       -> "BACKGROUND"
            ComponentCallbacks2.TRIM_MEMORY_MODERATE         -> "MODERATE"
            ComponentCallbacks2.TRIM_MEMORY_COMPLETE         -> "COMPLETE"
            else -> "level=$level"
        }
        CastLogger.warning("onTrimMemory: $label")
    }

    override fun onDestroy() {
        super.onDestroy()
        player?.release()
        player = null
    }

    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_SUBTITLE_URL = "subtitle_url"
        const val EXTRA_VIDEO_TRACK = "video_track"
        const val EXTRA_AUDIO_TRACK = "audio_track"
        const val EXTRA_SUBTITLE_TRACK = "subtitle_track"
    }
}
