package dev.overalls.mila.nativeui

data class MilaMachineCreateRequest(val name: String, val cpu: Int, val memoryMiB: Int, val diskGiB: Int) {
    init {
        require(name.trim().isNotEmpty() && name.length <= 128) { "invalid machine name" }
        require(cpu in 1..256) { "invalid cpu" }
        require(memoryMiB in 256..1_048_576) { "invalid memory" }
        require(diskGiB in 1..65_536) { "invalid disk" }
    }
    fun json(): String = "{\"name\":\"${name.jsonEscaped()}\",\"cpu\":$cpu,\"memory_mib\":$memoryMiB,\"disk_gib\":$diskGiB}"
    private fun String.jsonEscaped(): String = buildString(length) {
        for (c in this@jsonEscaped) when (c) {
            '\\' -> append("\\\\"); '\"' -> append("\\\""); '\n' -> append("\\n"); '\r' -> append("\\r"); '\t' -> append("\\t")
            else -> if (c.code < 0x20) append("\\u%04x".format(c.code)) else append(c)
        }
    }
}

suspend fun MilaFfiAdapter.createMachine(request: MilaMachineCreateRequest): Result<Unit> =
    when (call(MilaFfiRequest(MilaFfiOperation.MachineCreate, MilaFfiPayload(request.json().toByteArray(Charsets.UTF_8))))) {
        is MilaFfiResult.Success -> Result.success(Unit)
        is MilaFfiResult.Failure -> Result.failure(IllegalStateException("machine create unavailable"))
    }
