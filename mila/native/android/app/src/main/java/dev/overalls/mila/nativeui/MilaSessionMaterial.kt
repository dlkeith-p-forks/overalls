package dev.overalls.mila.nativeui

import android.content.Context
import kotlinx.coroutines.Dispatchers
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
class AndroidMilaSessionMaterialProvider(private val context: Context) : MilaSessionMaterialProvider {
    override suspend fun resolve(deployment: MilaDeployment): Result<MilaSessionMaterial> = withContext(Dispatchers.IO) {
        runCatching {
            val trust = context.assets.open("trust/${deployment.host}.json").use { input ->
                input.readBytes().also { require(it.size in 1..8192) { "invalid trust document size" } }
            }
            val signer = MilaDeviceKey.open(deployment.host)
            MilaSessionMaterial(
                MilaSessionConnectConfig(trust, signer.publicKey()),
                signer,
            )
        }
    }
}
