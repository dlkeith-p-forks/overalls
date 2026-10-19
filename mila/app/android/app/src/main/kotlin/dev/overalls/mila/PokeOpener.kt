package dev.overalls.mila

import org.bouncycastle.crypto.InvalidCipherTextException
import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.AEADParameters
import org.bouncycastle.crypto.params.HKDFParameters
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.math.ec.rfc7748.X25519
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

/**
 * Opens end-to-end encrypted pokes, format v1 (ADR-0224, ADR-0225), exactly
 * as `mila_core`'s `openPoke` and `protocol/test/fixtures/push_pokes.json`:
 * `0x01 || ephemeral_public(32) || nonce(12) || ciphertext || tag(16)` in
 * unpadded base64url; key = HKDF-SHA256(X25519(device, ephemeral), salt =
 * ephemeral_public || device_public, info = "overalls-mila-poke-v1", 32);
 * ChaCha20-Poly1305 with AAD "overalls-mila-poke-v1" || 0x00 || host; plaintext
 * exactly {v: 1, kind: "needs_input", route: "/..."}.
 */
// @cc [owner:ghuntley,label:security;protocol] mila-native-poke-open-v1
// The native opener MUST refuse, without throwing, anything but an authentic
// v1 poke sealed to a stored device key for that key's deployment host, with
// exactly `{v: 1, kind: "needs_input", route}`. Refusals MUST NOT carry or log
// poke bytes, keys or plaintext.
object PokeOpener {
    const val LABEL = "overalls-mila-poke-v1"
    private const val MINIMUM_BYTES = 1 + 32 + 12 + 16
    private const val MAXIMUM_PLAINTEXT = 512
    private const val MAXIMUM_BYTES = MINIMUM_BYTES + MAXIMUM_PLAINTEXT
    private const val ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

    enum class Refusal { ENCODING, LENGTH, VERSION, AUTHENTICATION, PLAINTEXT }

    data class Poke(val kind: String, val route: String)

    sealed class Opening {
        data class Opened(val poke: Poke) : Opening()
        data class Refused(val reason: Refusal) : Opening()
    }

    /** The X25519 public key for a 32-byte private key. */
    fun publicKey(private: ByteArray): ByteArray {
        require(private.size == 32) { "private" }
        return ByteArray(32).also { X25519.scalarMultBase(private, 0, it, 0) }
    }

    fun encodeBase64Url(data: ByteArray): String {
        val out = StringBuilder()
        var i = 0
        while (i < data.size) {
            val b0 = data[i].toInt() and 0xff
            val b1 = if (i + 1 < data.size) data[i + 1].toInt() and 0xff else 0
            val b2 = if (i + 2 < data.size) data[i + 2].toInt() and 0xff else 0
            out.append(ALPHABET[b0 shr 2])
            out.append(ALPHABET[((b0 and 3) shl 4) or (b1 shr 4)])
            if (i + 1 < data.size) out.append(ALPHABET[((b1 and 15) shl 2) or (b2 shr 6)])
            if (i + 2 < data.size) out.append(ALPHABET[b2 and 63])
            i += 3
        }
        return out.toString()
    }

    /** Strict unpadded base64url: no padding, no other alphabet, canonical only. */
    fun decodeBase64Url(text: String): ByteArray? {
        if (text.length % 4 == 1) return null
        val values = IntArray(text.length)
        for ((index, c) in text.withIndex()) {
            val value = ALPHABET.indexOf(c)
            if (value < 0) return null
            values[index] = value
        }
        val out = java.io.ByteArrayOutputStream(text.length * 3 / 4)
        var i = 0
        while (i < values.size) {
            val n = minOf(4, values.size - i)
            var group = 0
            for (j in 0 until 4) group = (group shl 6) or (if (j < n) values[i + j] else 0)
            out.write((group shr 16) and 0xff)
            if (n > 2) out.write((group shr 8) and 0xff)
            if (n > 3) out.write(group and 0xff)
            i += 4
        }
        val bytes = out.toByteArray()
        return if (encodeBase64Url(bytes) == text) bytes else null
    }

    fun associatedData(host: String): ByteArray =
        LABEL.toByteArray(StandardCharsets.US_ASCII) + byteArrayOf(0) + host.toByteArray(StandardCharsets.US_ASCII)

    fun open(poke: String, host: String, private: ByteArray): Opening {
        if (poke.length > (MAXIMUM_BYTES * 4 + 2) / 3) return Opening.Refused(Refusal.LENGTH)
        val bytes = decodeBase64Url(poke) ?: return Opening.Refused(Refusal.ENCODING)
        if (bytes.size < MINIMUM_BYTES || bytes.size > MAXIMUM_BYTES) return Opening.Refused(Refusal.LENGTH)
        if (bytes[0] != 1.toByte()) return Opening.Refused(Refusal.VERSION)
        if (private.size != 32 || host.isEmpty() || host.any { it.code > 127 }) {
            return Opening.Refused(Refusal.AUTHENTICATION)
        }
        val ephemeral = bytes.copyOfRange(1, 33)
        val nonce = bytes.copyOfRange(33, 45)
        val sealed = bytes.copyOfRange(45, bytes.size)
        val shared = ByteArray(32)
        // False for an all-zero (low-order) result, which is never authentic.
        if (!X25519.calculateAgreement(private, 0, ephemeral, 0, shared, 0)) {
            return Opening.Refused(Refusal.AUTHENTICATION)
        }
        val key = ByteArray(32)
        HKDFBytesGenerator(SHA256Digest()).run {
            init(HKDFParameters(shared, ephemeral + publicKey(private), LABEL.toByteArray(StandardCharsets.US_ASCII)))
            generateBytes(key, 0, 32)
        }
        val cipher = ChaCha20Poly1305()
        cipher.init(false, AEADParameters(KeyParameter(key), 128, nonce, associatedData(host)))
        val plaintext = ByteArray(cipher.getOutputSize(sealed.size))
        val length = try {
            val written = cipher.processBytes(sealed, 0, sealed.size, plaintext, 0)
            written + cipher.doFinal(plaintext, written)
        } catch (e: InvalidCipherTextException) {
            return Opening.Refused(Refusal.AUTHENTICATION)
        }
        val decoded = decodePlaintext(plaintext.copyOf(length)) ?: return Opening.Refused(Refusal.PLAINTEXT)
        return Opening.Opened(decoded)
    }

    /** Exactly three keys: v = integer 1, kind = needs_input, a route path. */
    fun decodePlaintext(plaintext: ByteArray): Poke? {
        if (plaintext.size > MAXIMUM_PLAINTEXT) return null
        val text = try {
            StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(plaintext)).toString()
        } catch (e: CharacterCodingException) {
            return null
        }
        val fields = FlatJson.parse(text) ?: return null
        if (fields.size != 3 || fields["v"] != 1L || fields["kind"] != "needs_input") return null
        val route = fields["route"] as? String ?: return null
        return if (validRoute(route)) Poke("needs_input", route) else null
    }

    /** A coarse shape check; the Dart router re-validates the closed table. */
    fun validRoute(route: String): Boolean =
        route.startsWith("/") && route.length <= 256 &&
            route.all { it in 'a'..'z' || it in '0'..'9' || it == '/' || it == '-' }
}

/**
 * A strict parser for one flat JSON object whose values are strings or
 * integers; anything else (nesting, fractions, duplicates) is refused. It
 * avoids `org.json`, which JVM unit tests cannot run.
 */
internal object FlatJson {
    fun parse(text: String): Map<String, Any>? = try {
        Parser(text).run { obj().also { space(); if (i != s.length) return null } }
    } catch (e: IllegalArgumentException) {
        null
    }

    private class Parser(val s: String) {
        var i = 0

        fun space() {
            while (i < s.length && s[i] in " \t\r\n") i++
        }

        fun expect(c: Char) {
            space()
            require(i < s.length && s[i] == c)
            i++
        }

        fun obj(): Map<String, Any> {
            expect('{')
            val out = LinkedHashMap<String, Any>()
            space()
            if (i < s.length && s[i] == '}') {
                i++
                return out
            }
            while (true) {
                space()
                val key = string()
                expect(':')
                space()
                require(i < s.length)
                val value: Any = if (s[i] == '"') string() else integer()
                require(out.put(key, value) == null)
                space()
                require(i < s.length)
                if (s[i] == ',') {
                    i++
                    continue
                }
                require(s[i] == '}')
                i++
                return out
            }
        }

        fun string(): String {
            require(i < s.length && s[i] == '"')
            i++
            val out = StringBuilder()
            while (true) {
                require(i < s.length)
                val c = s[i++]
                when {
                    c == '"' -> return out.toString()
                    c == '\\' -> {
                        require(i < s.length)
                        when (val e = s[i++]) {
                            '"', '\\', '/' -> out.append(e)
                            'b' -> out.append('\b')
                            'f' -> out.append('\u000c')
                            'n' -> out.append('\n')
                            'r' -> out.append('\r')
                            't' -> out.append('\t')
                            'u' -> {
                                require(i + 4 <= s.length)
                                out.append(s.substring(i, i + 4).toInt(16).toChar())
                                i += 4
                            }
                            else -> throw IllegalArgumentException()
                        }
                    }
                    c.code < 0x20 -> throw IllegalArgumentException()
                    else -> out.append(c)
                }
            }
        }

        fun integer(): Long {
            val start = i
            if (i < s.length && s[i] == '-') i++
            require(i < s.length && s[i] in '0'..'9')
            if (s[i] == '0') i++ else while (i < s.length && s[i] in '0'..'9') i++
            require(i == s.length || s[i] !in ".eE")
            require(i - start <= 18)
            return s.substring(start, i).toLong()
        }
    }
}
