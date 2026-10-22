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
class MilaTerminalController(private val adapter: MilaFfiAdapter) {
 var state = MilaTerminalState(); private set
 fun attach(readWrite: Boolean): Boolean = adapter.terminalAttach(0, state.columns, state.rows, readWrite).isSuccess.also { if (it) state = state.copy(phase = if (readWrite) MilaTerminalPhase.Attached else MilaTerminalPhase.ReadOnly) }
 fun resize(columns: Int, rows: Int): Boolean { if (columns !in 1..500 || rows !in 1..500) return false; return adapter.terminalResize(columns, rows, state.phase == MilaTerminalPhase.Attached).isSuccess.also { if (it) state = state.copy(columns=columns, rows=rows) } }
 fun close() { state = state.copy(phase = MilaTerminalPhase.Closed) }
}
