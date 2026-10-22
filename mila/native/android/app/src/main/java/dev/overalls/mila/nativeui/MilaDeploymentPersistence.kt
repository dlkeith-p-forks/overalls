package dev.overalls.mila.nativeui

import android.content.SharedPreferences

/** Durable, validated deployment selection. Credentials and tokens never enter this store. */
interface MilaDeploymentStore {
    fun read(): MilaDeployment?
    fun write(deployment: MilaDeployment)
    fun clear()
    fun readApproval(): MilaApprovalState = MilaApprovalState.NotRequired
    fun writeApproval(state: MilaApprovalState) {}
}

class MilaSharedPreferencesDeploymentStore(private val preferences: SharedPreferences) : MilaDeploymentStore {
    override fun read(): MilaDeployment? {
        val host = preferences.getString(KEY_HOST, null) ?: return null
        val port = preferences.getInt(KEY_PORT, 22)
        val label = preferences.getString(KEY_LABEL, host) ?: host
        return runCatching { MilaDeployment(host, port, label) }.getOrNull()
    }

    override fun write(deployment: MilaDeployment) {
        preferences.edit().putString(KEY_HOST, deployment.host)
            .putInt(KEY_PORT, deployment.port).putString(KEY_LABEL, deployment.label).apply()
    }

    override fun clear() { preferences.edit().clear().apply() }
    override fun readApproval(): MilaApprovalState = runCatching {
        MilaApprovalState.valueOf(preferences.getString(KEY_APPROVAL, MilaApprovalState.NotRequired.name)!!)
    }.getOrDefault(MilaApprovalState.NotRequired)
    override fun writeApproval(state: MilaApprovalState) { preferences.edit().putString(KEY_APPROVAL, state.name).apply() }

    private companion object { const val KEY_HOST = "host"; const val KEY_PORT = "port"; const val KEY_LABEL = "label"; const val KEY_APPROVAL = "approval" }
}

/** Session approval is explicit and survives reconnect attempts without persisting secrets. */
enum class MilaApprovalState { NotRequired, Pending, Approved, Rejected }
