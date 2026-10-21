package dev.overalls.mila.nativeui

import androidx.test.ext.junit.runners.AndroidJUnit4
import java.math.BigInteger
import java.security.KeyStore
import java.security.Signature
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MilaDeviceKeyTest {
    @Test
    fun keysRemainNonexportableDistinctPersistentAndSignCorrectMessage() {
        val hosts = List(2) { "custody-${UUID.randomUUID()}.example" }
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        try {
            val first = MilaDeviceKey.open(hosts[0])
            val second = MilaDeviceKey.open(hosts[1])
            assertFalse(first.publicKey() == second.publicKey())
            assertEquals(first.publicKey(), MilaDeviceKey.open(hosts[0]).publicKey())
            val alias = "dev.overalls.mila.device.${hosts[0]}"
            assertNull(store.getKey(alias, null).encoded)
            val message = "synthetic SSH authentication message".toByteArray()
            val raw = first.sign(message)
            assertEquals(64, raw.size)
            val r = BigInteger(1, raw.copyOfRange(0, 32)).toByteArray()
            val s = BigInteger(1, raw.copyOfRange(32, 64)).toByteArray()
            val der = byteArrayOf(0x30, (r.size + s.size + 4).toByte(), 2, r.size.toByte()) + r + byteArrayOf(2, s.size.toByte()) + s
            fun verifies(bytes: ByteArray): Boolean = Signature.getInstance("SHA256withECDSA").run {
                initVerify(store.getCertificate(alias).publicKey)
                update(bytes)
                verify(der)
            }
            assertTrue(verifies(message))
            assertFalse(verifies(message + byteArrayOf(1)))
            assertThrows(IllegalArgumentException::class.java) { first.sign(ByteArray(65537)) }
            store.deleteEntry(alias)
            assertThrows(IllegalStateException::class.java) { first.sign(message) }
            assertFalse(store.containsAlias(alias))
        } finally {
            hosts.forEach { store.deleteEntry("dev.overalls.mila.device.$it") }
        }
    }

    @Test
    fun invalidHostsNeverReachKeystore() {
        listOf("", "EXAMPLE.com", "example.com/path", "example.com:22", " localhost", "-bad.example").forEach { host ->
            assertThrows(IllegalArgumentException::class.java) { MilaDeviceKey.open(host) }
        }
    }
}
