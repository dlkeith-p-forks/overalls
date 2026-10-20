package dev.overalls.mila.nativeui

import java.util.UUID

sealed interface MilaRoute {
    data object Machines : MilaRoute
    data class Machine(val id: UUID) : MilaRoute
    data object Threads : MilaRoute
    data class Thread(val id: UUID) : MilaRoute
    data object Settings : MilaRoute
}

/** Parses only navigation routes; query strings and command-like paths are rejected. */
fun parseMilaRoute(value: String): MilaRoute? {
    val uri = runCatching { android.net.Uri.parse(value) }.getOrNull() ?: return null
    if (uri.scheme != "overalls" || uri.encodedQuery != null || uri.fragment != null || uri.authority?.contains('@') == true) return null
    val parts = uri.pathSegments
    return when (uri.host?.lowercase() to parts) {
        "machines" to emptyList() -> MilaRoute.Machines
        "threads" to emptyList() -> MilaRoute.Threads
        "settings" to emptyList() -> MilaRoute.Settings
        else -> when {
            uri.host?.lowercase() == "machines" && parts.size == 1 ->
                parts[0].toUuid()?.let(MilaRoute::Machine)
            uri.host?.lowercase() == "threads" && parts.size == 1 ->
                parts[0].toUuid()?.let(MilaRoute::Thread)
            else -> null
        }
    }
}

private fun String.toUuid(): UUID? = runCatching { UUID.fromString(this) }.getOrNull()

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
    data object IncompatibleAbi : MilaFfiError
    data object InvalidRoute : MilaFfiError
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

/** JNI entry points backed by the stable `mila-ffi` C ABI in the host application. */
internal object MilaRustFfi {
    init {
        runCatching { System.loadLibrary("mila_ffi") }
    }

    @JvmStatic
    external fun abiVersion(): Int

    @JvmStatic
    external fun canonicalRoute(value: String): String?
}

/** Typed Android adapter. Native linkage is lazy so the UI remains testable without a device. */
class LinkedMilaFfiAdapter : MilaFfiAdapter {
    override suspend fun call(request: MilaFfiRequest): MilaFfiResult {
        request.operation
        return try {
            if (MilaRustFfi.abiVersion() != 1) MilaFfiResult.Failure(MilaFfiError.IncompatibleAbi)
            else MilaFfiResult.Success(MilaFfiResponse(request.payload))
        } catch (_: UnsatisfiedLinkError) {
            MilaFfiResult.Failure(MilaFfiError.Unavailable)
        }
    }

    fun canonicalizeRoute(value: String): Result<String> = runCatching {
        MilaRustFfi.canonicalRoute(value) ?: throw IllegalArgumentException("invalid route")
    }.recoverCatching { error ->
        if (error is IllegalArgumentException) throw error
        throw error
    }
}
