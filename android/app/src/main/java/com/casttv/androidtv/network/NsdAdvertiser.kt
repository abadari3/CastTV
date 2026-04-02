package com.casttv.androidtv.network

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log

/**
 * Advertises this Android TV on the local network via NSD (mDNS/Bonjour)
 * so iPhones can discover it for quick-connect pairing.
 *
 * Publishes a `_casttv._tcp` service with room code, encryption key,
 * and device name in TXT records — matching the tvOS BonjourAdvertiser.
 */
class NsdAdvertiser(private val context: Context) {

    companion object {
        const val SERVICE_TYPE = "_casttv._tcp"
        private const val TAG = "NsdAdvertiser"
    }

    private var nsdManager: NsdManager? = null
    private var registrationListener: NsdManager.RegistrationListener? = null

    /**
     * Start advertising the given room code and encryption key on the local network.
     */
    fun start(roomCode: String, keyBase64URL: String, deviceName: String) {
        stop()

        val serviceInfo = NsdServiceInfo().apply {
            serviceName = "CastTV-$roomCode"
            serviceType = SERVICE_TYPE
            setAttribute("room", roomCode)
            setAttribute("key", keyBase64URL)
            setAttribute("name", deviceName)
        }

        val manager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
        nsdManager = manager

        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.i(TAG, "NSD advertising started for room $roomCode")
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "NSD registration failed: error $errorCode")
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) {
                Log.i(TAG, "NSD advertising stopped")
            }

            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "NSD unregistration failed: error $errorCode")
            }
        }
        registrationListener = listener

        manager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    /**
     * Stop advertising.
     */
    fun stop() {
        registrationListener?.let { listener ->
            try {
                nsdManager?.unregisterService(listener)
            } catch (e: IllegalArgumentException) {
                // Already unregistered
            }
        }
        registrationListener = null
        nsdManager = null
    }
}
