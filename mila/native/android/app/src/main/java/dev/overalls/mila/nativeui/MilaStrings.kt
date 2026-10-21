package dev.overalls.mila.nativeui

import java.util.Locale

/** Typed, shared message identities. Translations are kept in native resources at build time. */
internal enum class MilaMessage { AppName, Machines, Threads, Settings, Ready, Refresh, Connecting, Connected, RuntimeUnavailable, NoAction }

internal object MilaStrings {
    private val english = mapOf(
        MilaMessage.AppName to "Mila", MilaMessage.Machines to "Machines", MilaMessage.Threads to "Threads",
        MilaMessage.Settings to "Settings", MilaMessage.Ready to "Ready", MilaMessage.Refresh to "Refresh",
        MilaMessage.Connecting to "Connecting…", MilaMessage.Connected to "Connected",
        MilaMessage.RuntimeUnavailable to "Native runtime unavailable", MilaMessage.NoAction to "No action selected",
    )
    fun text(message: MilaMessage, locale: Locale = Locale.getDefault()): String =
        // Message identities are shared with the Rust catalog; missing native translations fall back to English.
        english.getValue(message)
}
