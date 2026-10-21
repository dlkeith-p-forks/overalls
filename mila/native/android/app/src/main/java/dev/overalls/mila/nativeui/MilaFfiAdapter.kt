package dev.overalls.mila.nativeui

import java.util.UUID
import java.net.URI

sealed interface MilaRoute {
    data object Machines : MilaRoute
    data class Machine(val id: UUID) : MilaRoute
    data object Threads : MilaRoute
    data class Thread(val id: UUID) : MilaRoute
    data object Settings : MilaRoute
}

/** Parses only navigation routes; query strings and command-like paths are rejected. */
fun parseMilaRoute(value: String): MilaRoute? {
    val uri = runCatching { URI(value) }.getOrNull() ?: return null
    if (uri.scheme != "overalls" || uri.rawQuery != null || uri.rawFragment != null || uri.rawAuthority?.contains('@') == true) return null
    val path = uri.rawPath ?: return null
    if (path.isNotEmpty() && path != "/" && path.contains("//")) return null
    val parts = path.trim('/').takeIf { it.isNotEmpty() }?.split('/') ?: emptyList()
    if (parts.any { it.contains('%') }) return null
    uri.host ?: return null
    val page = parts.firstOrNull() ?: return null
    val tail = parts.drop(1)
    return when {
        page == "machines" && tail.isEmpty() -> MilaRoute.Machines
        page == "threads" && tail.isEmpty() -> MilaRoute.Threads
        page == "settings" && tail.isEmpty() -> MilaRoute.Settings
        page == "machines" && tail.size == 1 -> tail[0].toUuid()?.let(MilaRoute::Machine)
        page == "threads" && tail.size == 1 -> tail[0].toUuid()?.let(MilaRoute::Thread)
        else -> null
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

/** Narrow JNI surface implemented by the host application's Rust `mila-ffi` library. */
interface MilaRustBindings {
    fun abiVersion(): Int
    fun canonicalRoute(value: String): String?
    /** Returns the closed machine-action bit mask, or null for invalid input. */
    fun machineActions(snapshot: ByteArray, host: String, port: Int?, index: Int): Int?
}

/** JNI entry points backed by the stable `mila-ffi` C ABI in the host application. */
internal object MilaRustFfi : MilaRustBindings {
    private val loaded: Boolean = runCatching {
        System.loadLibrary("mila_ffi")
        true
    }.getOrDefault(false)

    override fun abiVersion(): Int {
        check(loaded) { "mila_ffi is unavailable" }
        return nativeAbiVersion()
    }

    override fun canonicalRoute(value: String): String? {
        check(loaded) { "mila_ffi is unavailable" }
        return nativeCanonicalRoute(value)
    }

    override fun machineActions(snapshot: ByteArray, host: String, port: Int?, index: Int): Int? {
        check(loaded) { "mila_ffi is unavailable" }
        val value = nativeMachineActions(snapshot, host, port ?: 0, port != null, index)
        return value.takeUnless { it < 0 }
    }

    @JvmStatic
    external fun nativeAbiVersion(): Int

    @JvmStatic
    external fun nativeCanonicalRoute(value: String): String?

    @JvmStatic
    external fun nativeMachineActions(snapshot: ByteArray, host: String, port: Int, hasPort: Boolean, index: Int): Int
}

/** Typed Android adapter. Native linkage is lazy so the UI remains testable without a device. */
class LinkedMilaFfiAdapter(
    private val bindings: MilaRustBindings = MilaRustFfi,
) : MilaFfiAdapter {
    override suspend fun call(request: MilaFfiRequest): MilaFfiResult {
        return try {
            if (bindings.abiVersion() != 1) MilaFfiResult.Failure(MilaFfiError.IncompatibleAbi)
            else MilaFfiResult.Success(MilaFfiResponse(request.payload))
        } catch (_: UnsatisfiedLinkError) {
            MilaFfiResult.Failure(MilaFfiError.Unavailable)
        } catch (_: IllegalStateException) {
            MilaFfiResult.Failure(MilaFfiError.Unavailable)
        }
    }

    fun canonicalizeRoute(value: String): Result<String> = runCatching {
        bindings.canonicalRoute(value) ?: throw IllegalArgumentException("invalid route")
    }

    fun machineActions(snapshot: ByteArray, host: String, port: Int?, index: Int): Result<Int> = runCatching {
        bindings.machineActions(snapshot, host, port, index) ?: throw IllegalArgumentException("invalid snapshot")
    }
}
