package dev.overalls.mila.nativeui

import android.content.Context
import java.util.concurrent.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** Inputs required by the Rust session connector; no credential bytes are retained by the UI. */
data class MilaSessionMaterial(val config: MilaSessionConnectConfig, val signer: MilaDeviceKey)

/** Resolves deployment trust and the non-exportable device signer at the native boundary. */
fun interface MilaSessionMaterialProvider {
    suspend fun resolve(deployment: MilaDeployment): Result<MilaSessionMaterial>
}

/**
 * Android's host-provided trust bundle convention. The app deliberately has no fallback trust:
 * a missing or malformed `trust/<host>.json` asset leaves sign-in unavailable.
 */
/**
 * @cc [owner:ghuntley,label:security] android-trust-read-bounded
 * Trust reads MUST consume at most 8193 bytes and reject empty or over-8192-byte assets
 * before opening a device key. Coroutine cancellation MUST propagate to the caller.
 */
class AndroidMilaSessionMaterialProvider(private val context: Context) : MilaSessionMaterialProvider {
    override suspend fun resolve(deployment: MilaDeployment): Result<MilaSessionMaterial> = withContext(Dispatchers.IO) {
        try {
            val trust = context.assets.open("trust/${deployment.host}.json").use { input ->
                val buffer = ByteArray(8193)
                var size = 0
                while (size < buffer.size) {
                    coroutineContext.ensureActive()
                    val count = input.read(buffer, size, buffer.size - size)
                    if (count == -1) break
                    size += count
                }
                require(size in 1..8192) { "invalid trust document size" }
                buffer.copyOf(size)
            }
            coroutineContext.ensureActive()
            val signer = MilaDeviceKey.open(deployment.host)
            Result.success(MilaSessionMaterial(
                MilaSessionConnectConfig(trust, signer.publicKey()),
                signer,
            ))
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            Result.failure(failure)
        }
    }
}
