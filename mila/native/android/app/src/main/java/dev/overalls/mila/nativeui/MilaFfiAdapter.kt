package dev.overalls.mila.nativeui

/** The operation names exported by the generated Rust FFI binding. */
@JvmInline
value class MilaFfiOperation private constructor(val value: String) {
    companion object {
        val Bootstrap: MilaFfiOperation = MilaFfiOperation("bootstrap")
        val Refresh: MilaFfiOperation = MilaFfiOperation("refresh")
    }
}

/** Immutable byte ownership at the native/Rust boundary. */
class MilaFfiPayload(bytes: ByteArray) {
    private val value: ByteArray = bytes.copyOf()

    fun copyBytes(): ByteArray = value.copyOf()
}

data class MilaFfiRequest(
    val operation: MilaFfiOperation,
    val payload: MilaFfiPayload = MilaFfiPayload(byteArrayOf()),
)

data class MilaFfiResponse(val payload: MilaFfiPayload)

sealed interface MilaFfiError {
    data object Unavailable : MilaFfiError
}

sealed interface MilaFfiResult {
    data class Success(val response: MilaFfiResponse) : MilaFfiResult
    data class Failure(val error: MilaFfiError) : MilaFfiResult
}

/**
 * @cc [owner:ghuntley,label:security] mila-android-ffi-typed-boundary
 * The Android UI MUST exchange only typed `MilaFfiRequest` and `MilaFfiResponse` values with Rust;
 * raw pointers, credentials, and terminal bytes MUST NOT appear in this interface.
 */
interface MilaFfiAdapter {
    suspend fun call(request: MilaFfiRequest): MilaFfiResult
}

/** Explicit placeholder until generated Rust bindings are linked by the host app. */
object UnavailableMilaFfiAdapter : MilaFfiAdapter {
    override suspend fun call(request: MilaFfiRequest): MilaFfiResult {
        request.operation
        return MilaFfiResult.Failure(MilaFfiError.Unavailable)
    }
}
