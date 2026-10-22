package dev.overalls.mila.nativeui

import android.content.SharedPreferences

/** Persisted user preferences shared by the Android shell and its tests. */
enum class MilaAppearance { System, Light, Dark }

data class MilaSettings(
    val appearance: MilaAppearance = MilaAppearance.System,
    val locale: String = "en",
) {
    init {
        require(locale.matches(Regex("^[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8})*$"))) { "invalid locale" }
    }
}

interface MilaSettingsStore {
    fun read(key: String): String?
    fun write(key: String, value: String)
}

class MilaSharedPreferencesStore(private val preferences: SharedPreferences) : MilaSettingsStore {
    override fun read(key: String): String? = preferences.getString(key, null)
    override fun write(key: String, value: String) { preferences.edit().putString(key, value).apply() }
}

/** Typed boundary around platform key/value storage; malformed values fall back safely. */
class MilaSettingsController(private val store: MilaSettingsStore) {
    fun load(): MilaSettings {
        val appearance = when (store.read(KEY_APPEARANCE)?.lowercase()) {
            "light" -> MilaAppearance.Light
            "dark" -> MilaAppearance.Dark
            else -> MilaAppearance.System
        }
        val locale = store.read(KEY_LOCALE)?.takeIf { it.matches(LOCALE_PATTERN) } ?: "en"
        return MilaSettings(appearance, locale)
    }

    fun save(settings: MilaSettings) {
        store.write(KEY_APPEARANCE, settings.appearance.name.lowercase())
        store.write(KEY_LOCALE, settings.locale)
    }

    private companion object {
        const val KEY_APPEARANCE = "mila.appearance"
        const val KEY_LOCALE = "mila.locale"
        val LOCALE_PATTERN = Regex("^[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8})*$")
    }
}
