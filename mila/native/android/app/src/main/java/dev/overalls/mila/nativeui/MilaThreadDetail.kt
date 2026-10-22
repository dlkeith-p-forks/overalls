package dev.overalls.mila.nativeui

import java.util.UUID

data class MilaThreadRow(val id: UUID, val title: String, val status: String)
data class MilaThreadListing(val threads: List<MilaThreadRow>, val hasMore: Boolean)

sealed interface MilaThreadActionState {
    data object SignedOut : MilaThreadActionState
    data object Idle : MilaThreadActionState
    data class Ready(val thread: MilaThreadRow) : MilaThreadActionState
    data class Submitting(val thread: MilaThreadRow, val command: MilaThreadCommand) : MilaThreadActionState
    data class Applied(val thread: MilaThreadRow, val command: MilaThreadCommand) : MilaThreadActionState
    data class Failed(val thread: MilaThreadRow, val command: MilaThreadCommand, val reason: String) : MilaThreadActionState
}

class MilaThreadDetailController(private val adapter: MilaFfiAdapter) {
    var state: MilaThreadActionState = MilaThreadActionState.SignedOut
        private set
    private var listing: MilaThreadListing? = null
    private var authenticated = false

    fun setSession(signedIn: Boolean, current: MilaThreadListing?) {
        val active = signedIn && current != null
        if (active == authenticated && current == listing) return
        authenticated = active
        listing = if (active) current else null
        state = if (active) MilaThreadActionState.Idle else MilaThreadActionState.SignedOut
    }

    fun select(id: UUID): Boolean {
        val thread = listing?.threads?.firstOrNull { it.id == id } ?: return false
        state = MilaThreadActionState.Ready(thread)
        return true
    }

    suspend fun submit(command: MilaThreadCommand): Boolean {
        val thread = (state as? MilaThreadActionState.Ready)?.thread ?: return false
        if (!authenticated) { state = MilaThreadActionState.SignedOut; return false }
        state = MilaThreadActionState.Submitting(thread, command)
        return adapter.threadAction(thread.id, command).fold(
            { state = MilaThreadActionState.Applied(thread, command); true },
            { error -> state = MilaThreadActionState.Failed(thread, command, error.message ?: "command rejected"); false },
        )
    }
}
