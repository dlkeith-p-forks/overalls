package dev.overalls.mila

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Receives data-only FCM pokes (ADR-0224), opens them with every stored
 * deployment key and posts a notification whose tap opens the poke's route.
 * A poke no key opens is dropped.
 */
// @cc [owner:ghuntley,label:security;privacy] mila-native-notification-fixed-text
// A notification MUST carry only the fixed localized title and body and, for
// an authentic poke, the `overalls://` link of its route. It MUST NOT show or
// log poke bytes, plaintext, keys or tokens.
class MilaMessagingService : FirebaseMessagingService() {
    companion object {
        const val CHANNEL_ID = "mila.needs_input"
    }

    override fun onCreate() {
        MilaFirebase.app(applicationContext)
        super.onCreate()
    }

    override fun onNewToken(token: String) {
        MilaPlatform.tokenChanged(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val poke = message.data["poke"] ?: return
        for ((host, private) in PokeKeys(this).all()) {
            val opening = PokeOpener.open(poke, host, private)
            if (opening is PokeOpener.Opening.Opened) {
                post(Uri.parse("overalls://$host${opening.poke.route}"))
                return
            }
        }
    }

    private fun post(link: Uri) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val title = getString(R.string.mila_needs_input_title)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, title, NotificationManager.IMPORTANCE_HIGH),
            )
        }
        val intent = Intent(Intent.ACTION_VIEW, link, this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val tap = PendingIntent.getActivity(
            this,
            link.hashCode(),
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this).setPriority(Notification.PRIORITY_HIGH)
        }
        val notification = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(getString(R.string.mila_needs_input_body))
            .setContentIntent(tap)
            .setAutoCancel(true)
            .build()
        manager.notify(link.toString().hashCode(), notification)
    }
}
