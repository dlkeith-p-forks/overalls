package dev.overalls.mila.nativeui

import android.content.Context
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** Inputs required by the Rust session connector; no credential bytes are retained by the UI. */
data class MilaSessionMaterial(val config: MilaSessionConnectConfig, val signer: MilaDeviceKey)

/** Bounded local pin storage owned by the platform application. */
interface MilaTrustStore {
    fun read(host: String): ByteArray?
    fun write(host: String, document: ByteArray)
}

/** Fetches only the deployment's HTTPS trust endpoint. */
fun interface MilaTrustFetcher {
    suspend fun fetch(host: String): ByteArray
}

private const val MAX_TRUST_BYTES = 8192

/** Android app-private trust storage with crash-safe replacement. */
class AndroidMilaTrustStore(private val context: Context) : MilaTrustStore {
    private fun file(host: String): File = File(File(context.filesDir, "trust"), "$host.json")

    override fun read(host: String): ByteArray? = runCatching {
        val target = file(host)
        if (!target.isFile) return null
        FileInputStream(target).use { input ->
            val bytes = ByteArray(MAX_TRUST_BYTES + 1)
            var size = 0
            while (size < bytes.size) {
                val count = input.read(bytes, size, bytes.size - size)
                if (count < 0) break
                size += count
            }
            if (size in 1..MAX_TRUST_BYTES) bytes.copyOf(size) else null
        }
    }.getOrNull()

    override fun write(host: String, document: ByteArray) {
        require(document.isNotEmpty() && document.size <= MAX_TRUST_BYTES) { "invalid trust document" }
        val directory = File(context.filesDir, "trust").apply { mkdirs() }
        val target = file(host)
        val temporary = File(directory, "$host.json.new")
        FileOutputStream(temporary).use { output ->
            output.write(document)
            output.fd.sync()
        }
        try {
            Files.move(
                temporary.toPath(), target.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
        } catch (failure: Exception) {
            temporary.delete()
            throw failure
        }
    }
}

/** HTTPS/system-trust fetcher for `/bin/ssh-trust.json`; redirects are refused. */
class AndroidMilaTrustFetcher(
    private val connectTimeoutMs: Int = 15_000,
    private val readTimeoutMs: Int = 15_000,
) : MilaTrustFetcher {
    override suspend fun fetch(host: String): ByteArray = withContext(Dispatchers.IO) {
        val connection = (URL("https://$host/bin/ssh-trust.json").openConnection() as HttpURLConnection).apply {
            instanceFollowRedirects = false
            connectTimeout = connectTimeoutMs
            readTimeout = readTimeoutMs
            requestMethod = "GET"
        }
        try {
            require(connection.responseCode in 200..299) { "trust fetch refused" }
            require(connection.contentLengthLong in -1L..MAX_TRUST_BYTES.toLong()) { "trust document too large" }
            connection.inputStream.use { input ->
                val bytes = ByteArray(MAX_TRUST_BYTES + 1)
                var size = 0
                while (size < bytes.size) {
                    coroutineContext.ensureActive()
                    val count = input.read(bytes, size, bytes.size - size)
                    if (count < 0) break
                    size += count
                }
                require(size in 1..MAX_TRUST_BYTES) { "invalid trust document size" }
                bytes.copyOf(size)
            }
        } finally {
            connection.disconnect()
        }
    }
}

/** Shared enrollment orchestration: fetch, Rust validation/reconciliation, then atomic persist. */
class MilaTrustEnrollment(
    private val bindings: MilaRustBindings,
    private val store: MilaTrustStore,
    private val fetcher: MilaTrustFetcher,
    private val clock: () -> Long = { System.currentTimeMillis() / 1000 },
) {
    /**
     * @cc [owner:ghuntley,label:security] android-trust-enrollment-order
     * Android MUST fetch trust over HTTPS, pass both fetched and pinned bytes to
     * Rust reconciliation, and persist only Rust's canonical output atomically.
     * Transport failure may use an unretired pin; malformed or conflicting
     * fetched data MUST fail closed.
     */
    suspend fun resolve(host: String): Result<ByteArray> = withContext(Dispatchers.IO) {
        try {
            val pinned = store.read(host)
            val fetched = try {
                fetcher.fetch(host)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                null
            }
            coroutineContext.ensureActive()
            val selected = bindings.reconcileTrust(pinned, fetched, host, clock())
                ?: return@withContext Result.failure(IllegalStateException("trust refused"))
            if (pinned == null || !pinned.contentEquals(selected)) store.write(host, selected)
            Result.success(selected.copyOf())
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            Result.failure(failure)
        }
    }
}

/** Resolves deployment trust and the non-exportable device signer at the native boundary. */
fun interface MilaSessionMaterialProvider {
    suspend fun resolve(deployment: MilaDeployment): Result<MilaSessionMaterial>
}

/** Native Android session material provider using deployment enrollment. */
class AndroidMilaSessionMaterialProvider(
    context: Context,
    bindings: MilaRustBindings = MilaRustFfi,
    fetcher: MilaTrustFetcher = AndroidMilaTrustFetcher(),
    trustStore: MilaTrustStore = AndroidMilaTrustStore(context),
    clock: () -> Long = { System.currentTimeMillis() / 1000 },
) : MilaSessionMaterialProvider {
    private val enrollment = MilaTrustEnrollment(bindings, trustStore, fetcher, clock)

    override suspend fun resolve(deployment: MilaDeployment): Result<MilaSessionMaterial> =
        enrollment.resolve(deployment.host).mapCatching { trust ->
            val signer = MilaDeviceKey.open(deployment.host)
            MilaSessionMaterial(
                MilaSessionConnectConfig(trust, signer.publicKey()),
                signer,
            )
        }
}
