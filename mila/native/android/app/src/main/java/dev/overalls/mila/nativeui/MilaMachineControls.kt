package dev.overalls.mila.nativeui

/** UI-facing typed machine action result; operation names never bypass Rust classification. */
sealed interface MilaMachineActionState {
 data object Idle : MilaMachineActionState
 data class Selected(val action: MilaMachineCommand) : MilaMachineActionState
 data class Rejected(val reason: String) : MilaMachineActionState
}

class MilaMachineActionController(private val adapter: MilaFfiAdapter) {
 var state: MilaMachineActionState = MilaMachineActionState.Idle; private set
 fun select(command: String) { state = adapter.machineCommandKind(command).fold({ MilaMachineActionState.Selected(it) }, { MilaMachineActionState.Rejected("unknown action") }) }
}

enum class MilaTerminalPhase { Idle, Attached, ReadOnly, Closed }
data class MilaTerminalState(val phase: MilaTerminalPhase = MilaTerminalPhase.Idle, val columns: Int = 80, val rows: Int = 24)
/** Bounded terminal text projection; control bytes and unbounded history never reach Compose. */
class MilaTerminalRenderer {
    private val lines = ArrayDeque<String>()
    fun append(bytes: ByteArray) {
        val text = bytes.toString(Charsets.UTF_8)
        text.split('\n').forEach { raw ->
            val clean = raw.filter { it == '\t' || it.code >= 0x20 && it != '\u007f' }.take(4096)
            if (lines.size == 200) lines.removeFirst()
            lines.addLast(clean)
        }
    }
    fun text(): String = lines.joinToString("\n")
}
class MilaTerminalController(private val adapter: MilaFfiAdapter) {
 var state = MilaTerminalState(); private set
 val renderer = MilaTerminalRenderer()
 fun attach(readWrite: Boolean): Boolean = adapter.terminalAttach(0, state.columns, state.rows, readWrite).isSuccess.also { if (it) state = state.copy(phase = if (readWrite) MilaTerminalPhase.Attached else MilaTerminalPhase.ReadOnly) }
 fun reconnect(readWrite: Boolean = state.phase == MilaTerminalPhase.Attached): Boolean { if (state.phase == MilaTerminalPhase.Closed) state = state.copy(phase = MilaTerminalPhase.Idle); return attach(readWrite) }
 fun input(length: Int): Boolean = state.phase == MilaTerminalPhase.Attached && adapter.terminalInput(length, true).isSuccess
 fun resize(columns: Int, rows: Int): Boolean { if (columns !in 1..500 || rows !in 1..500) return false; return adapter.terminalResize(columns, rows, state.phase == MilaTerminalPhase.Attached).isSuccess.also { if (it) state = state.copy(columns=columns, rows=rows) } }
 fun close() { state = state.copy(phase = MilaTerminalPhase.Closed) }
}
