package dev.overalls.mila.nativeui

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.math.BigInteger
import java.security.interfaces.ECPublicKey
import java.util.Base64

/** Wire-only encoding: private key material never enters this type. */
internal object MilaP256Encoding {
    private fun coordinate(value: BigInteger): ByteArray {
        require(value.signum() >= 0 && value.bitLength() <= 256)
        val encoded = value.toByteArray()
        val unsigned = if (encoded.size == 33 && encoded[0] == 0.toByte()) encoded.copyOfRange(1, 33) else encoded
        return ByteArray(32 - unsigned.size) + unsigned
    }

    fun openSsh(key: ECPublicKey): String {
        val point = byteArrayOf(4) + coordinate(key.w.affineX) + coordinate(key.w.affineY)
        val buffer = ByteArrayOutputStream()
        DataOutputStream(buffer).use { output ->
            for (part in listOf("ecdsa-sha2-nistp256".toByteArray(Charsets.US_ASCII), "nistp256".toByteArray(Charsets.US_ASCII), point)) {
                output.writeInt(part.size)
                output.write(part)
            }
        }
        return "ecdsa-sha2-nistp256 " + Base64.getEncoder().encodeToString(buffer.toByteArray())
    }

    /**
     * @cc [owner:ghuntley,label:security] native-android-p256-der
     * Conversion MUST reject trailing bytes, nonminimal or negative integers, zero scalars,
     * and scalars outside the P-256 order; accepted signatures MUST be exactly 64 bytes.
     */
    fun fixedSignature(der: ByteArray): ByteArray {
        require(der.size in 8..72 && der[0] == 0x30.toByte() && der[1].toInt() == der.size - 2)
        var offset = 2
        val order = BigInteger("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551", 16)
        fun scalar(): ByteArray {
            require(offset + 2 <= der.size && der[offset++] == 2.toByte())
            val length = der[offset++].toInt()
            require(length in 1..33 && offset + length <= der.size)
            val bytes = der.copyOfRange(offset, offset + length)
            offset += length
            require(bytes[0].toInt() >= 0)
            require(length == 1 || bytes[0] != 0.toByte() || bytes[1].toInt() < 0)
            val value = BigInteger(bytes)
            require(value.signum() > 0 && value < order)
            return coordinate(value)
        }
        val fixed = scalar() + scalar()
        require(offset == der.size)
        return fixed
    }
}
