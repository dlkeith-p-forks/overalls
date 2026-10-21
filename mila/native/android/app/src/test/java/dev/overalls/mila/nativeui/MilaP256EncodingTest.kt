package dev.overalls.mila.nativeui

import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.Base64
import kotlin.random.Random
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class MilaP256EncodingTest {
    @Test
    fun convertsGeneratedP256PublicKeysAndSignatures() {
        val generator = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }
        val random = Random(249)
        repeat(128) {
            val pair = generator.generateKeyPair()
            val key = pair.public as ECPublicKey
            val encoded = MilaP256Encoding.openSsh(key)
            val input = DataInputStream(ByteArrayInputStream(Base64.getDecoder().decode(encoded.substringAfter(' '))))
            fun field(): ByteArray = ByteArray(input.readInt()).also { input.readFully(it) }
            assertEquals("ecdsa-sha2-nistp256", String(field(), Charsets.US_ASCII))
            assertEquals("nistp256", String(field(), Charsets.US_ASCII))
            val point = field()
            assertEquals(65, point.size)
            assertEquals(4, point[0].toInt())
            assertEquals(key.w.affineX, java.math.BigInteger(1, point.copyOfRange(1, 33)))
            assertEquals(key.w.affineY, java.math.BigInteger(1, point.copyOfRange(33, 65)))
            assertEquals(-1, input.read())
            val der = Signature.getInstance("SHA256withECDSA").run {
                initSign(pair.private)
                update(random.nextBytes(random.nextInt(1, 1024)))
                sign()
            }
            val fixed = MilaP256Encoding.fixedSignature(der)
            assertEquals(64, fixed.size)
            val rLength = der[3].toInt()
            val sLength = der[5 + rLength].toInt()
            assertEquals(java.math.BigInteger(der.copyOfRange(4, 4 + rLength)), java.math.BigInteger(1, fixed.copyOfRange(0, 32)))
            assertEquals(java.math.BigInteger(der.copyOfRange(6 + rLength, 6 + rLength + sLength)), java.math.BigInteger(1, fixed.copyOfRange(32, 64)))
        }
    }

    @Test
    fun rejectsMalformedDerWithoutPartialResults() {
        val valid = byteArrayOf(0x30, 6, 2, 1, 1, 2, 1, 1)
        assertArrayEquals(ByteArray(31) + byteArrayOf(1) + ByteArray(31) + byteArrayOf(1), MilaP256Encoding.fixedSignature(valid))
        val invalid = listOf(
            byteArrayOf(), valid + byteArrayOf(0), valid.copyOf(7),
            byteArrayOf(0x30, 6, 2, 1, 0, 2, 1, 1),
            byteArrayOf(0x30, 6, 2, 1, -1, 2, 1, 1),
            byteArrayOf(0x30, 7, 2, 2, 0, 1, 2, 1, 1),
            byteArrayOf(0x30, 6, 2, -1, 1, 2, 1, 1),
        )
        invalid.forEach { bytes -> assertThrows(IllegalArgumentException::class.java) { MilaP256Encoding.fixedSignature(bytes) } }
    }
}
