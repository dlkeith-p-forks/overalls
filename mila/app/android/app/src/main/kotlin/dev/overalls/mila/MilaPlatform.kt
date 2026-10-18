package dev.overalls.mila

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

/**
 * The `dev.overalls.mila/platform` channel (ADR-0220): one P-256 device key
 * per deployment host in the Android Keystore, StrongBox-backed when the
 * device has StrongBox, and `overalls://` links. Private keys are
 * non-exportable; only the public point and DER signatures cross the channel.
 */
class MilaPlatform(
    private val context: Context,
    private val channel: MethodChannel,
    /** The link the activity was launched with, until Dart asks for it. */
    private var initialLink: String?,
) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "dev.overalls.mila/platform"
        private const val KEYSTORE = "AndroidKeyStore"
        private val HOST = Regex("^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "link.initial" -> {
                    result.success(initialLink)
                    initialLink = null
                }
                "deviceKey.public" -> result.success(publicPoint(host(call)))
                "deviceKey.sign" -> {
                    val data = call.argument<ByteArray>("data")
                        ?: return result.error("invalid_argument", "data", null)
                    result.success(sign(host(call), data))
                }
                "dataDirectory" -> result.success(context.filesDir.absolutePath)
                "openUrl" -> {
                    val uri = Uri.parse(call.argument<String>("url") ?: "")
                    if (uri.scheme != "https") return result.error("invalid_argument", "url", null)
                    context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: IllegalArgumentException) {
            result.error("invalid_argument", e.message, null)
        } catch (e: Exception) {
            // Keystore failures carry no key material; report only the class.
            result.error("keystore_unavailable", e.javaClass.simpleName, null)
        }
    }

    /** Sends a link that arrived while running. */
    fun deliver(link: String) = channel.invokeMethod("link", link)

    private fun host(call: MethodCall): String {
        val host = call.argument<String>("host") ?: ""
        require(HOST.matches(host)) { "host" }
        return host
    }

    private fun alias(host: String) = "dev.overalls.mila.device.$host"

    private fun keyStore(): KeyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }

    private fun generate(alias: String, strongBox: Boolean) {
        val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
        if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) spec.setIsStrongBoxBacked(true)
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE).apply {
            initialize(spec.build())
            generateKeyPair()
        }
    }

    private fun ensure(host: String): String {
        val alias = alias(host)
        if (!keyStore().containsAlias(alias)) {
            try {
                generate(alias, strongBox = true)
            } catch (e: StrongBoxUnavailableException) {
                generate(alias, strongBox = false)
            }
        }
        return alias
    }

    /** The uncompressed point `04 || X || Y`, 65 bytes. */
    private fun publicPoint(host: String): ByteArray {
        val key = keyStore().getCertificate(ensure(host)).publicKey as ECPublicKey
        fun coordinate(value: BigInteger): ByteArray {
            val bytes = value.toByteArray().dropWhile { it == 0.toByte() }.toByteArray()
            require(bytes.size <= 32) { "coordinate" }
            return ByteArray(32 - bytes.size) + bytes
        }
        return byteArrayOf(4) + coordinate(key.w.affineX) + coordinate(key.w.affineY)
    }

    /** A DER ECDSA signature over SHA-256 of [data]. */
    private fun sign(host: String, data: ByteArray): ByteArray {
        val key = keyStore().getKey(ensure(host), null) as PrivateKey
        return Signature.getInstance("SHA256withECDSA").run {
            initSign(key)
            update(data)
            sign()
        }
    }
}
