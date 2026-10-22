package dev.overalls.mila.nativeui

import android.content.SharedPreferences

data class MilaNotificationDevice(val id: String, val enabled: Boolean)
interface MilaNotificationStore { fun list(): List<MilaNotificationDevice>; fun setEnabled(id: String, enabled: Boolean): Boolean; fun remove(id: String): Boolean }

/** Durable device registration projection. Tokens are owned by the OS push provider and are
 * deliberately never persisted here; only the provider registration id and user toggle remain. */
class MilaPreferencesNotificationStore(private val preferences: SharedPreferences) : MilaNotificationStore {
    private val key = "registered_devices"
    override fun list(): List<MilaNotificationDevice> = preferences.getStringSet(key, emptySet()).orEmpty()
        .mapNotNull { encoded ->
            val parts = encoded.split("|", limit = 2)
            if (parts.size == 2 && validId(parts[0])) MilaNotificationDevice(parts[0], parts[1] == "1") else null
        }.sortedBy { it.id }

    override fun setEnabled(id: String, enabled: Boolean): Boolean {
        if (!validId(id) || !list().any { it.id == id }) return false
        val next = list().map { if (it.id == id) it.copy(enabled = enabled) else it }
        persist(next); return true
    }

    fun register(id: String, enabled: Boolean = true): Boolean {
        if (!validId(id)) return false
        val next = list().filterNot { it.id == id } + MilaNotificationDevice(id, enabled)
        persist(next); return true
    }

    override fun remove(id: String): Boolean {
        val next = list().filterNot { it.id == id }
        if (next.size == list().size) return false
        persist(next); return true
    }

    private fun persist(value: List<MilaNotificationDevice>) {
        preferences.edit().putStringSet(key, value.map { "${it.id}|${if (it.enabled) 1 else 0}" }.toSet()).apply()
    }

    private fun validId(id: String): Boolean = id.length in 1..256 && id.all { it.isLetterOrDigit() || it in ".:_-" }
}
class MilaNotificationController(private val store: MilaNotificationStore) {
 var devices: List<MilaNotificationDevice> = store.list().filter { it.id.isNotBlank() }; private set
 fun refresh() { devices = store.list().filter { it.id.isNotBlank() } }
 fun setEnabled(id: String, enabled: Boolean): Boolean = store.setEnabled(id, enabled).also { if (it) refresh() }
 fun remove(id: String): Boolean = store.remove(id).also { if (it) refresh() }
}
