package dev.overalls.mila.nativeui

import java.util.Locale
import android.content.Context
import org.json.JSONObject

/** Typed, shared message identities. Translations are kept in native resources at build time. */
internal enum class MilaMessage(val catalogId: String) {
    AppName("appTitle"), Machines("machinesTitle"), Threads("tabThreads"), Settings("settingsTitle"),
    Ready("ready"), Refresh("refresh"), Connecting("signInConnecting"), Connected("connected"),
    LockTitle("lockTitle"), LockExplain("lockExplain"), LockUnlock("lockUnlock"), LockFailed("lockFailed"),
    RuntimeUnavailable("runtimeUnavailable"), NoAction("noAction"), Terminal("tabTerminals"), Attach("terminalAttach"), Input("terminalAttach"), Resize("actionResize"), MachineActions("machineMore"), SharePrincipal("sharePrincipal"), ShareAdd("shareAdd"), ShareRemove("shareRemove"), ShareRejected("shareRejected"), ShareAdded("shareAdded"), ShareRemoved("shareRemoved"), Appearance("appearance"), Locale("locale"), ThreadCommands("tabThreads"), NoCommand("noAction"), WebEndpoint("webEndpoint"), WebShow("webOpen"), WebSave("webSave"), WebPort("webPort"), WebPublic("webPublic"), WebPrivate("webPrivate")
}

internal object MilaStrings {
    private var catalog: Map<String, String> = emptyMap()
    private val english = mapOf(
        MilaMessage.AppName to "Mila", MilaMessage.Machines to "Machines", MilaMessage.Threads to "Threads",
        MilaMessage.Settings to "Settings", MilaMessage.Ready to "Ready", MilaMessage.Refresh to "Refresh",
        MilaMessage.LockTitle to "App lock", MilaMessage.LockExplain to "Authenticate to continue.", MilaMessage.LockUnlock to "Unlock", MilaMessage.LockFailed to "Authentication failed.",
        MilaMessage.Connecting to "Connecting…", MilaMessage.Connected to "Connected",
        MilaMessage.RuntimeUnavailable to "Native runtime unavailable", MilaMessage.NoAction to "No action selected", MilaMessage.Terminal to "Terminals", MilaMessage.Attach to "Attach", MilaMessage.Input to "Input", MilaMessage.Resize to "Resize", MilaMessage.MachineActions to "Machine actions", MilaMessage.SharePrincipal to "Share principal", MilaMessage.ShareAdd to "Share add", MilaMessage.ShareRemove to "Share remove", MilaMessage.ShareRejected to "Share rejected", MilaMessage.ShareAdded to "Share added", MilaMessage.ShareRemoved to "Share removed", MilaMessage.Appearance to "Appearance", MilaMessage.Locale to "Locale", MilaMessage.ThreadCommands to "Thread commands", MilaMessage.NoCommand to "No command selected", MilaMessage.WebEndpoint to "Web endpoint", MilaMessage.WebShow to "Show", MilaMessage.WebSave to "Save", MilaMessage.WebPort to "Port", MilaMessage.WebPublic to "Public", MilaMessage.WebPrivate to "Private",
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
