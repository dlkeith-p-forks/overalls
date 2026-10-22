package dev.overalls.mila.nativeui

data class MilaNotificationDevice(val id: String, val enabled: Boolean)
interface MilaNotificationStore { fun list(): List<MilaNotificationDevice>; fun setEnabled(id: String, enabled: Boolean): Boolean; fun remove(id: String): Boolean }
class MilaNotificationController(private val store: MilaNotificationStore) {
 var devices: List<MilaNotificationDevice> = store.list().filter { it.id.isNotBlank() }; private set
 fun refresh() { devices = store.list().filter { it.id.isNotBlank() } }
 fun setEnabled(id: String, enabled: Boolean): Boolean = store.setEnabled(id, enabled).also { if (it) refresh() }
 fun remove(id: String): Boolean = store.remove(id).also { if (it) refresh() }
}
