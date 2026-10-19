package dev.overalls.mila

import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions

/**
 * Initializes Firebase from Gradle properties (`mila.fcm.*`, compiled into
 * BuildConfig) instead of the google-services plugin, so builds without push
 * credentials still work and simply report `push_unavailable`.
 */
object MilaFirebase {
    /** The default app, or null when this build carries no FCM configuration. */
    @Synchronized
    fun app(context: Context): FirebaseApp? {
        FirebaseApp.getApps(context).firstOrNull { it.name == FirebaseApp.DEFAULT_APP_NAME }?.let { return it }
        val fields = listOf(
            BuildConfig.MILA_FCM_PROJECT_ID,
            BuildConfig.MILA_FCM_APPLICATION_ID,
            BuildConfig.MILA_FCM_API_KEY,
            BuildConfig.MILA_FCM_SENDER_ID,
        )
        if (fields.any { it.isEmpty() }) return null
        val options = FirebaseOptions.Builder()
            .setProjectId(BuildConfig.MILA_FCM_PROJECT_ID)
            .setApplicationId(BuildConfig.MILA_FCM_APPLICATION_ID)
            .setApiKey(BuildConfig.MILA_FCM_API_KEY)
            .setGcmSenderId(BuildConfig.MILA_FCM_SENDER_ID)
            .build()
        return FirebaseApp.initializeApp(context.applicationContext, options)
    }
}
