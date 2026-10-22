package dev.overalls.mila.nativeui

data class MilaSshKey(val fingerprint: String, val label: String, val revoked: Boolean = false)
interface MilaSshKeyStore { fun list(): List<MilaSshKey>; fun revoke(fingerprint: String): Boolean }
class MilaSshKeyController(private val store: MilaSshKeyStore) {
 var keys: List<MilaSshKey> = store.list().filter { it.fingerprint.isNotBlank() }; private set
 fun refresh() { keys = store.list().filter { it.fingerprint.isNotBlank() } }
 fun revoke(fingerprint: String): Boolean { val ok = store.revoke(fingerprint); if (ok) refresh(); return ok }
}
