package dev.overalls.mila.nativeui

/** Validated deployment entry shown by the native sign-in selector. */
data class MilaDeployment(val host: String, val port: Int = 22, val label: String = host) {
    init { require(host.matches(HOST)) { "invalid deployment host" }; require(port in 1..65535) }
    companion object { private val HOST = Regex("^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$") }
}

/** Deterministic, duplicate-free deployment selection model. */
class MilaDeploymentSelection(initial: List<MilaDeployment> = emptyList()) {
    private val entries = initial.distinctBy { it.host to it.port }.toMutableList()
    val deployments: List<MilaDeployment> get() = entries.toList()
    var selected: MilaDeployment? = entries.firstOrNull(); private set
    fun add(deployment: MilaDeployment) { if (entries.none { it.host == deployment.host && it.port == deployment.port }) entries += deployment; if (selected == null) selected = deployment }
    fun select(host: String, port: Int = 22): Boolean = entries.firstOrNull { it.host == host && it.port == port }?.let { selected = it; true } ?: false
}
