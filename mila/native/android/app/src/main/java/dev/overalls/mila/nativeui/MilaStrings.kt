package dev.overalls.mila.nativeui

import java.util.Locale
import android.content.Context
import org.json.JSONObject

/** Typed, shared message identities. Translations are kept in native resources at build time. */
internal enum class MilaMessage(val catalogId: String) {
    AppName("appTitle"), Machines("machinesTitle"), Threads("tabThreads"), Settings("settingsTitle"),
    Ready("ready"), Refresh("refresh"), Connecting("signInConnecting"), Connected("connected"),
    RuntimeUnavailable("runtimeUnavailable"), NoAction("noAction")
}

internal object MilaStrings {
    private var catalog: Map<String, String> = emptyMap()
    private val english = mapOf(
        MilaMessage.AppName to "Mila", MilaMessage.Machines to "Machines", MilaMessage.Threads to "Threads",
        MilaMessage.Settings to "Settings", MilaMessage.Ready to "Ready", MilaMessage.Refresh to "Refresh",
        MilaMessage.Connecting to "Connecting…", MilaMessage.Connected to "Connected",
        MilaMessage.RuntimeUnavailable to "Native runtime unavailable", MilaMessage.NoAction to "No action selected",
    )
    fun configure(context: Context, locale: Locale = Locale.getDefault()) {
        val tag = locale.toLanguageTag().replace('_', '-')
        val candidates = listOf(tag, locale.language, "en")
        catalog = candidates.asSequence().mapNotNull { candidate ->
            runCatching {
                val json = context.assets.open("${candidate}.json").bufferedReader().use { it.readText() }
                val messages = JSONObject(json).getJSONObject("domains").getJSONObject("mila").getJSONArray("messages")
                buildMap {
                    for (index in 0 until messages.length()) {
                        val message = messages.getJSONObject(index)
                        val forms = message.getJSONArray("forms")
                        if (forms.length() > 0) put(message.getString("id"), forms.getString(0))
                    }
                }
            }.getOrNull()
        }.firstOrNull().orEmpty()
    }

    fun text(message: MilaMessage, locale: Locale = Locale.getDefault()): String =
        catalog[message.catalogId] ?: english.getValue(message)
}
