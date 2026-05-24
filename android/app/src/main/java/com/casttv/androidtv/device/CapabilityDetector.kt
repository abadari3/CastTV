package com.casttv.androidtv.device

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.view.Display
import android.view.WindowManager
import com.casttv.androidtv.network.AudioCapabilities
import com.casttv.androidtv.network.CapabilitiesMessage
import com.casttv.androidtv.network.DisplayCapabilities

/**
 * Detects Android TV display and audio capabilities.
 * Sends these to the iPhone so it can show correct compatibility indicators.
 */
object CapabilityDetector {
    fun detect(context: Context): CapabilitiesMessage {
        val display = detectDisplay(context)
        val audio = detectAudio(context)
        val androidVersion = "Android ${Build.VERSION.RELEASE}"

        return CapabilitiesMessage(
            model = "${Build.MANUFACTURER} ${Build.MODEL}",
            tvOS = androidVersion,
            name = Build.MODEL,
            display = display,
            audio = audio,
        )
    }

    private fun detectDisplay(context: Context): DisplayCapabilities {
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val display =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                context.display
            } else {
                @Suppress("DEPRECATION")
                wm.defaultDisplay
            }

        val mode = display?.mode
        val width = mode?.physicalWidth ?: 1920
        val height = mode?.physicalHeight ?: 1080
        val refreshRate = mode?.refreshRate?.toInt() ?: 60

        val resolution =
            when {
                width >= 3840 || height >= 2160 -> "4K"
                width >= 1920 || height >= 1080 -> "1080p"
                width >= 1280 || height >= 720 -> "720p"
                else -> "${width}x$height"
            }

        val hdrModes = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val hdrCaps = display?.hdrCapabilities
            hdrCaps?.supportedHdrTypes?.forEach { type ->
                when (type) {
                    Display.HdrCapabilities.HDR_TYPE_HDR10 -> hdrModes.add("hdr10")
                    Display.HdrCapabilities.HDR_TYPE_HDR10_PLUS -> hdrModes.add("hdr10plus")
                    Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION -> hdrModes.add("dolbyVision")
                    Display.HdrCapabilities.HDR_TYPE_HLG -> hdrModes.add("hlg")
                }
            }
        }

        val availableModes =
            display?.supportedModes?.map {
                "${it.physicalWidth}x${it.physicalHeight}@${it.refreshRate.toInt()}"
            } ?: listOf("${width}x$height@$refreshRate")

        return DisplayCapabilities(
            resolution = resolution,
            availableModes = availableModes,
            maxRefreshRate = refreshRate,
            displayGamut = "sRGB",
            hdrModes = hdrModes,
        )
    }

    private fun detectAudio(context: Context): AudioCapabilities {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

        var maxChannels = 2
        var outputType = "built-in"
        var atmosSupported = false

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val outputs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            for (device in outputs) {
                when (device.type) {
                    AudioDeviceInfo.TYPE_HDMI, AudioDeviceInfo.TYPE_HDMI_ARC -> {
                        outputType = "hdmi"
                        val channels = device.channelCounts.maxOrNull() ?: 2
                        if (channels > maxChannels) maxChannels = channels
                        if (device.encodings.contains(android.media.AudioFormat.ENCODING_E_AC3_JOC)) {
                            atmosSupported = true
                        }
                    }
                    AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET -> {
                        if (outputType != "hdmi") outputType = "usb"
                    }
                }
            }
        }

        if (maxChannels > 8) maxChannels = 8

        return AudioCapabilities(
            maxChannels = maxChannels,
            outputType = outputType,
            atmosSupported = atmosSupported,
            spatialAudioEnabled = false,
        )
    }
}
