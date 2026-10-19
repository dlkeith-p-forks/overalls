package dev.overalls.mila

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Per-deployment X25519 poke keys. Each private key is stored in app-private
 * SharedPreferences `dev.overalls.mila.poke` as base64(iv || AES-256-GCM(key))
 * under a non-exportable Android Keystore wrapping key, so the messaging
 * service in the same process can open pokes while Mila is not running.
 */
// @cc [owner:ghuntley,label:security] mila-poke-keys-stay-native
// Poke private keys MUST stay wrapped by the Keystore key in app-private
// storage. Only the 32-byte public key MAY cross the platform channel; private
// keys MUST NOT be logged or exported.
class PokeKeys(context: Context) {
    companion object {
        private const val PREFERENCES = "dev.overalls.mila.poke"
        private const val WRAP_ALIAS = "dev.overalls.mila.poke-wrap"
        private const val KEYSTORE = "AndroidKeyStore"
        private const val IV_BYTES = 12
    }

    private val preferences = context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    private fun wrappingKey(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(WRAP_ALIAS, null) as? SecretKey)?.let { return it }
        val spec = KeyGenParameterSpec.Builder(WRAP_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE).run {
            init(spec)
            generateKey()
        }
    }

    private fun unwrap(stored: String): ByteArray? = try {
        val blob = Base64.decode(stored, Base64.NO_WRAP)
        if (blob.size <= IV_BYTES) {
            null
        } else {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, wrappingKey(), GCMParameterSpec(128, blob, 0, IV_BYTES))
            cipher.doFinal(blob, IV_BYTES, blob.size - IV_BYTES).takeIf { it.size == 32 }
        }
    } catch (e: Exception) {
        null
    }

    private fun wrap(private: ByteArray): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        // The Keystore chooses the IV for an encrypting GCM key.
        cipher.init(Cipher.ENCRYPT_MODE, wrappingKey())
        return Base64.encodeToString(cipher.iv + cipher.doFinal(private), Base64.NO_WRAP)
    }

    /** The public key for [host], creating its private key on first use. */
    fun publicKey(host: String): ByteArray {
        val existing = preferences.getString(host, null)?.let(::unwrap)
        val private = existing ?: ByteArray(32).also {
            SecureRandom().nextBytes(it)
            check(preferences.edit().putString(host, wrap(it)).commit()) { "storage" }
        }
        return PokeOpener.publicKey(private)
    }

    fun delete(host: String) {
        preferences.edit().remove(host).commit()
    }

    /** Every stored (host, private key) pair that unwraps. */
    fun all(): List<Pair<String, ByteArray>> =
        preferences.all.mapNotNull { (host, value) ->
            (value as? String)?.let(::unwrap)?.let { host to it }
        }
}
