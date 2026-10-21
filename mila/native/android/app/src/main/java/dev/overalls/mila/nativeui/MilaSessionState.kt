package dev.overalls.mila.nativeui

/** Connection state owned by the native session boundary, rather than inferred by the UI. */
sealed interface MilaSessionConnection {
    data object Idle : MilaSessionConnection
    data object Refreshing : MilaSessionConnection
    data class Connected(val listing: MilaSessionListing) : MilaSessionConnection
    data class Failed(val error: MilaFfiError) : MilaSessionConnection
}

/** Runs one bounded refresh and converts every native outcome into typed UI state. */
internal object MilaSessionRefresher {
    suspend fun refresh(adapter: MilaFfiAdapter): MilaSessionConnection {
        return when (val result = adapter.call(MilaFfiRequest(MilaFfiOperation.Refresh))) {
            is MilaFfiResult.Failure -> MilaSessionConnection.Failed(result.error)
            is MilaFfiResult.Success -> runCatching {
                MilaSessionListing.decode(result.response.payload.copyBytes())
            }.fold(
                onSuccess = { MilaSessionConnection.Connected(it) },
                onFailure = { MilaSessionConnection.Failed(MilaFfiError.Unavailable) },
            )
        }
    }
}
