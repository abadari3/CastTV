package com.casttv.androidtv.ui

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Divider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.casttv.androidtv.network.ConnectionState

@Composable
fun HomeScreen(
    roomCode: String,
    qrBitmap: Bitmap?,
    connectionState: ConnectionState,
    connectedDeviceName: String?,
    errorMessage: String?,
    qrString: String,
) {
    Column(modifier = Modifier.fillMaxSize().padding(40.dp)) {
        Row(
            modifier = Modifier.weight(1f).fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(40.dp),
        ) {
            QRSection(
                roomCode = roomCode,
                qrBitmap = qrBitmap,
                connectionState = connectionState,
                modifier = Modifier.weight(1f).fillMaxHeight(),
            )

            Divider(
                modifier = Modifier.fillMaxHeight().width(1.dp).padding(vertical = 60.dp),
                color = Color.White.copy(alpha = 0.2f),
            )

            StatusSection(
                connectionState = connectionState,
                connectedDeviceName = connectedDeviceName,
                errorMessage = errorMessage,
                modifier = Modifier.weight(1f).fillMaxHeight(),
            )
        }

        if (qrString.isNotEmpty()) {
            Text(
                text = qrString,
                color = Color.White.copy(alpha = 0.2f),
                fontSize = 10.sp,
                fontFamily = FontFamily.Monospace,
                modifier = Modifier.padding(top = 16.dp).fillMaxWidth(),
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun QRSection(
    roomCode: String,
    qrBitmap: Bitmap?,
    connectionState: ConnectionState,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            text = "CastTV",
            color = Color.White,
            fontSize = 40.sp,
            fontWeight = FontWeight.Bold,
        )

        Spacer(Modifier.height(24.dp))

        if (connectionState == ConnectionState.CONNECTING && qrBitmap == null) {
            CircularProgressIndicator(color = Color.White)
        } else if (qrBitmap != null) {
            Image(
                bitmap = qrBitmap.asImageBitmap(),
                contentDescription = "Pairing QR Code",
                modifier =
                    Modifier
                        .size(280.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(Color.White),
            )

            Spacer(Modifier.height(16.dp))

            Text(
                text = "Scan with CastTV iPhone app",
                color = Color.White.copy(alpha = 0.7f),
                fontSize = 16.sp,
            )

            Spacer(Modifier.height(8.dp))

            Text(
                text = roomCode,
                color = Color.White.copy(alpha = 0.7f),
                fontSize = 20.sp,
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Medium,
            )
        }
    }
}

@Composable
private fun StatusSection(
    connectionState: ConnectionState,
    connectedDeviceName: String?,
    errorMessage: String?,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        when {
            connectedDeviceName != null -> {
                Text(text = "📱", fontSize = 48.sp)
                Spacer(Modifier.height(12.dp))
                Text(
                    text = "iPhone connected",
                    color = Color(0xFF34C759),
                    fontSize = 22.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    text = "Send a URL from your iPhone to start casting",
                    color = Color.White.copy(alpha = 0.6f),
                    fontSize = 16.sp,
                    textAlign = TextAlign.Center,
                )
            }
            connectionState == ConnectionState.CONNECTED -> {
                Text(text = "📱", fontSize = 48.sp)
                Spacer(Modifier.height(12.dp))
                Text(
                    text = "Ready",
                    color = Color.White,
                    fontSize = 22.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    text = "Open CastTV on your iPhone to cast",
                    color = Color.White.copy(alpha = 0.6f),
                    fontSize = 16.sp,
                    textAlign = TextAlign.Center,
                )
            }
            connectionState == ConnectionState.CONNECTING -> {
                CircularProgressIndicator(color = Color.White)
                Spacer(Modifier.height(12.dp))
                Text(
                    text = "Connecting...",
                    color = Color.White.copy(alpha = 0.6f),
                    fontSize = 16.sp,
                )
            }
            else -> {
                Text(
                    text = "Disconnected",
                    color = Color.White.copy(alpha = 0.4f),
                    fontSize = 16.sp,
                )
            }
        }

        errorMessage?.let {
            Spacer(Modifier.height(16.dp))
            Text(
                text = it,
                color = Color(0xFFFF3B30),
                fontSize = 14.sp,
                textAlign = TextAlign.Center,
            )
        }
    }
}

fun darkColorScheme() =
    androidx.compose.material3.darkColorScheme(
        background = Color.Black,
        surface = Color(0xFF1C1C1E),
        primary = Color.White,
    )
