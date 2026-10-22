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
        val MachineAction: MilaFfiOperation = MilaFfiOperation("machine_action")
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
    /** Executes a Rust-classified action for an authenticated machine session. */
    suspend fun machineAction(machineId: UUID, command: MilaMachineCommand): Result<Unit> =
        when (call(MilaFfiRequest(MilaFfiOperation.MachineAction, MilaFfiPayload(
            "{\"machine_id\":\"$machineId\",\"command\":${command.tag}}".toByteArray(Charsets.UTF_8)
        )))) {
            is MilaFfiResult.Success -> Result.success(Unit)
            is MilaFfiResult.Failure -> Result.failure(IllegalStateException("machine action unavailable"))
        }

    fun threadCommandKind(value: String): Result<MilaThreadCommand> = Result.failure(IllegalStateException("native runtime unavailable"))
    fun machineCommandKind(value: String): Result<MilaMachineCommand> = Result.failure(IllegalStateException("native runtime unavailable"))
    fun terminalAttach(from: Long, columns: Int, rows: Int, readWrite: Boolean): Result<Unit> = Result.failure(IllegalStateException("native runtime unavailable"))
    fun terminalInput(length: Int, readWrite: Boolean): Result<Unit> = Result.failure(IllegalStateException("native runtime unavailable"))
    fun terminalResize(columns: Int, rows: Int, readWrite: Boolean): Result<Unit> = Result.failure(IllegalStateException("native runtime unavailable"))
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
    fun sessionConnect(trust: ByteArray, host: String, publicKey: String, port: Int, timeoutMs: Int, signer: MilaDeviceKey): MilaSessionHandle?
    /** Returns the closed Rust thread-command tag, or -1 for an unknown command. */
    fun threadCommandKind(value: String): Int
    fun machineCommandKind(value: String): Int
    fun terminalAttach(from: Long, columns: Int, rows: Int, readWrite: Boolean): Int
    fun terminalInput(length: Int, readWrite: Boolean): Int
    fun terminalResize(columns: Int, rows: Int, readWrite: Boolean): Int
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

    override fun sessionConnect(trust: ByteArray, host: String, publicKey: String, port: Int, timeoutMs: Int, signer: MilaDeviceKey): MilaSessionHandle? {
        check(loaded) { "mila_ffi is unavailable" }
        return nativeSessionConnect(trust, host, publicKey, port, timeoutMs, signer)?.let(::MilaSessionHandle)
    }

    override fun threadCommandKind(value: String): Int {
        check(loaded) { "mila_ffi is unavailable" }
        return nativeThreadCommandKind(value)
    }

    override fun machineCommandKind(value: String): Int {
        check(loaded) { "mila_ffi is unavailable" }
        return nativeMachineCommandKind(value)
    }

    override fun terminalAttach(from: Long, columns: Int, rows: Int, readWrite: Boolean): Int = nativeTerminalAttach(from, columns, rows, readWrite)
    override fun terminalInput(length: Int, readWrite: Boolean): Int = nativeTerminalInput(length, readWrite)
    override fun terminalResize(columns: Int, rows: Int, readWrite: Boolean): Int = nativeTerminalResize(columns, rows, readWrite)

    @JvmStatic
    external fun nativeAbiVersion(): Int

    @JvmStatic
    external fun nativeCanonicalRoute(value: String): String?

    @JvmStatic
    external fun nativeMachineActions(snapshot: ByteArray, host: String, port: Int, hasPort: Boolean, index: Int): Int

    @JvmStatic
    external fun nativeSessionConnect(trust: ByteArray, host: String, publicKey: String, port: Int, timeoutMs: Int, signer: MilaDeviceKey): Long?
    @JvmStatic
    external fun nativeSessionRead(handle: Long, more: Boolean): Int
    @JvmStatic
    external fun nativeSessionListing(handle: Long): ByteArray?
    @JvmStatic
    external fun nativeSessionSnapshot(handle: Long): ByteArray?
    @JvmStatic
    external fun nativeSessionClose(handle: Long): Int
    @JvmStatic
    external fun nativeThreadCommandKind(value: String): Int
    @JvmStatic
    external fun nativeMachineCommandKind(value: String): Int
    @JvmStatic external fun nativeTerminalAttach(from: Long, columns: Int, rows: Int, readWrite: Boolean): Int
    @JvmStatic external fun nativeTerminalInput(length: Int, readWrite: Boolean): Int
    @JvmStatic external fun nativeTerminalResize(columns: Int, rows: Int, readWrite: Boolean): Int
}

/** Opaque, one-shot authority for a live Rust session. */
class MilaSessionHandle internal constructor(private val nativeHandle: Long) : AutoCloseable {
    private var closed = false
    @Synchronized fun readMachines(more: Boolean = false): Int { check(!closed); return MilaRustFfi.nativeSessionRead(nativeHandle, more) }
    @Synchronized fun listing(): ByteArray { check(!closed); return MilaRustFfi.nativeSessionListing(nativeHandle) ?: error("listing unavailable") }
    @Synchronized fun snapshot(): ByteArray { check(!closed); return MilaRustFfi.nativeSessionSnapshot(nativeHandle) ?: error("snapshot unavailable") }
    @Synchronized override fun close() { if (!closed) { MilaRustFfi.nativeSessionClose(nativeHandle); closed = true } }
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

    override fun threadCommandKind(value: String): Result<MilaThreadCommand> = runCatching {
        MilaThreadCommand.fromTag(bindings.threadCommandKind(value))
            ?: throw IllegalArgumentException("unknown thread command")
    }

    override fun machineCommandKind(value: String): Result<MilaMachineCommand> = runCatching {
        MilaMachineCommand.fromTag(bindings.machineCommandKind(value))
            ?: throw IllegalArgumentException("unknown machine command")
    }

    override fun terminalAttach(from: Long, columns: Int, rows: Int, readWrite: Boolean): Result<Unit> = status(bindings.terminalAttach(from, columns, rows, readWrite))
    override fun terminalInput(length: Int, readWrite: Boolean): Result<Unit> = status(bindings.terminalInput(length, readWrite))
    override fun terminalResize(columns: Int, rows: Int, readWrite: Boolean): Result<Unit> = status(bindings.terminalResize(columns, rows, readWrite))

    private fun status(value: Int): Result<Unit> = if (value == 0) Result.success(Unit) else Result.failure(IllegalArgumentException("terminal operation rejected"))
}

enum class MilaThreadCommand(val tag: Int) {
    List(1), Show(2), Turns(3), Prompt(4), Answer(5), PlanApprove(6),
    PlanRevise(7), Mode(8), Read(9);
    companion object { fun fromTag(tag: Int): MilaThreadCommand? = entries.firstOrNull { it.tag == tag } }
}

enum class MilaMachineCommand(val tag: Int) {
    List(1), Show(2), New(3), Resize(4), Start(5), Stop(6), Pause(7), Resume(8),
    Delete(9), ShareAdd(10), ShareRemove(11), WebShow(12), WebSet(13);
    companion object { fun fromTag(tag: Int): MilaMachineCommand? = entries.firstOrNull { it.tag == tag } }
}
