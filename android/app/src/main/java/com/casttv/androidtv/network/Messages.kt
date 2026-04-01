package com.casttv.androidtv.network

import com.google.gson.Gson
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.google.gson.annotations.SerializedName

// MARK: - iPhone → Android TV

data class PlayMessage(
    val action: String = "play",
    val url: String,
    @SerializedName("subtitleUrl") val subtitleUrl: String? = null,
    val tracks: TrackSelection? = null,
    val processing: ProcessingRequirements? = null
)

data class TrackSelection(
    val video: Int? = null,
    val audio: Int? = null,
    val subtitle: Int? = null
)

data class ProcessingRequirements(
    val remux: Boolean = false,
    val audioTranscode: AudioTranscodeReq? = null,
    val subtitleConvert: SubtitleConvertReq? = null
) {
    data class AudioTranscodeReq(val trackId: Int, val targetCodec: String = "aac")
    data class SubtitleConvertReq(val trackId: Int, val targetFormat: String = "webvtt")
}

// MARK: - Android TV → iPhone

data class CapabilitiesMessage(
    val type: String = "capabilities",
    val model: String,
    val tvOS: String,
    val name: String,
    val display: DisplayCapabilities,
    val audio: AudioCapabilities
)

data class DisplayCapabilities(
    val resolution: String,
    val availableModes: List<String>,
    val maxRefreshRate: Int,
    val displayGamut: String,
    val hdrModes: List<String>
)

data class AudioCapabilities(
    val maxChannels: Int,
    val outputType: String,
    val atmosSupported: Boolean,
    val spatialAudioEnabled: Boolean
)

data class ErrorMessage(
    val type: String = "error",
    val code: String,
    val message: String
)

data class LogMessage(
    val type: String = "log",
    val timestamp: String,
    val level: String,
    val message: String
)

data class LogsHistoryMessage(
    val type: String = "logs_history",
    val session: String,
    val entries: List<LogMessage>
)

// MARK: - Envelope

sealed class CastMessage {
    data class Play(val msg: PlayMessage) : CastMessage()
    data class Capabilities(val msg: CapabilitiesMessage) : CastMessage()
    data class Error(val msg: ErrorMessage) : CastMessage()
    data class Log(val msg: LogMessage) : CastMessage()
    object ClearLogs : CastMessage()
    data class DeviceJoined(val role: String) : CastMessage()
    data class DeviceLeft(val role: String) : CastMessage()
    data class Unknown(val raw: String) : CastMessage()
}

object MessageCodec {
    private val gson = Gson()

    fun decode(json: String): CastMessage {
        return try {
            val obj = JsonParser.parseString(json).asJsonObject
            val action = obj.getStringOrNull("action")
            val type = obj.getStringOrNull("type")

            when {
                action == "play" -> CastMessage.Play(gson.fromJson(obj, PlayMessage::class.java))
                action == "clear_logs" -> CastMessage.ClearLogs
                type == "capabilities" -> CastMessage.Capabilities(gson.fromJson(obj, CapabilitiesMessage::class.java))
                type == "error" -> CastMessage.Error(gson.fromJson(obj, ErrorMessage::class.java))
                type == "log" -> CastMessage.Log(gson.fromJson(obj, LogMessage::class.java))
                type == "device_joined" -> CastMessage.DeviceJoined(obj.getStringOrNull("role") ?: "unknown")
                type == "device_left" -> CastMessage.DeviceLeft(obj.getStringOrNull("role") ?: "unknown")
                else -> CastMessage.Unknown(json)
            }
        } catch (e: Exception) {
            CastMessage.Unknown(json)
        }
    }

    fun encode(msg: CapabilitiesMessage): String = gson.toJson(msg)
    fun encode(msg: LogMessage): String = gson.toJson(msg)
    fun encode(msg: LogsHistoryMessage): String = gson.toJson(msg)
    fun encode(msg: ErrorMessage): String = gson.toJson(msg)

    private fun JsonObject.getStringOrNull(key: String): String? =
        if (has(key) && !get(key).isJsonNull) get(key).asString else null
}
