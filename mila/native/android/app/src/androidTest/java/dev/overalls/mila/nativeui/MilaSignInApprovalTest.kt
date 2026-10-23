package dev.overalls.mila.nativeui

import androidx.test.ext.junit.runners.AndroidJUnit4
import java.security.KeyStore
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

private const val APPROVAL_FINGERPRINT = "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU"

private class ApprovalBindings(private val host: String) : MilaRustBindings {
    val connectCalls = AtomicInteger()
    val closeCalls = AtomicInteger()
    private val whoamiCalls = AtomicInteger()

    override fun abiVersion(): Int = 1
    override fun canonicalRoute(value: String): String? = value
    override fun machineActions(snapshot: ByteArray, host: String, port: Int?, index: Int): Int? = 0
    override fun sessionConnect(trust: ByteArray, host: String, publicKey: String, port: Int, timeoutMs: Int, signer: MilaDeviceKey): MilaSessionHandle {
        connectCalls.incrementAndGet()
        return MilaSessionHandle(7L, this)
    }
    override fun sessionWhoami(handle: Long): ByteArray {
        return if (whoamiCalls.getAndIncrement() == 0) {
            "{\"version\":1,\"status\":\"approval_required\",\"fingerprint\":\"$APPROVAL_FINGERPRINT\",\"approval_url\":\"https://$host/ssh/approve/test\"}".toByteArray()
        } else {
            "{\"version\":1,\"status\":\"succeeded\"}".toByteArray()
        }
    }
    override fun sessionRead(handle: Long, more: Boolean): Int = 0
    override fun sessionListing(handle: Long): ByteArray = "{\"machines\":[],\"has_more\":false}".toByteArray()
    override fun sessionClose(handle: Long): Int { closeCalls.incrementAndGet(); return 0 }
    override fun threadCommandKind(value: String): Int = 1
    override fun machineCommandKind(value: String): Int = 1
    override fun terminalAttach(from: Long, columns: Int, rows: Int, readWrite: Boolean): Int = 0
    override fun terminalInput(length: Int, readWrite: Boolean): Int = 0
    override fun terminalResize(columns: Int, rows: Int, readWrite: Boolean): Int = 0
}

private class ApprovalAdapter(private val bindings: ApprovalBindings) : MilaFfiAdapter, MilaSessionConnector {
    var bound: MilaSessionHandle? = null
    override suspend fun call(request: MilaFfiRequest): MilaFfiResult = MilaFfiResult.Failure(MilaFfiError.Unavailable)
    override fun connect(deployment: MilaDeployment, config: MilaSessionConnectConfig, signer: MilaDeviceKey): MilaSessionHandle? = bindings.sessionConnect(config.trustDocument, deployment.host, config.publicKey, deployment.port, config.timeoutMs, signer)
    override fun bindSession(session: MilaSessionHandle?) {
        bound?.close()
        bound = session
    }
}

private class ApprovalStore : MilaDeploymentStore {
    var deployment: MilaDeployment? = null
    override fun read(): MilaDeployment? = deployment
    override fun write(deployment: MilaDeployment) { this.deployment = deployment }
    override fun clear() { deployment = null }
}

@RunWith(AndroidJUnit4::class)
class MilaSignInApprovalTest {
    @Test
    fun approvalPollingReusesSessionAndPackagedReconnectCreatesOneFreshSession() = runBlocking {
        val deployment = MilaDeployment("approval-${System.nanoTime()}.mila.example", 443)
        val bindings = ApprovalBindings(deployment.host)
        val adapter = ApprovalAdapter(bindings)
        val store = ApprovalStore()
        val signer = MilaDeviceKey.open(deployment.host)
        val config = MilaSessionConnectConfig(byteArrayOf(1), signer.publicKey())
        val controller = MilaSignInController(adapter, store)

        try {
            controller.signIn(deployment, config, signer)
            assertTrue(controller.state is MilaSignInState.AwaitingApproval)
            assertTrue(controller.pollApproval())
            assertTrue(controller.state is MilaSignInState.SignedIn)
            assertEquals(1, bindings.connectCalls.get())
            assertNotNull(adapter.bound)

            controller.close()
            assertEquals(1, bindings.closeCalls.get())
            assertEquals(null, adapter.bound)
            assertTrue(controller.reconnect(config, signer))
            assertTrue(controller.state is MilaSignInState.SignedIn)
            assertEquals(2, bindings.connectCalls.get())
        } finally {
            controller.close()
            KeyStore.getInstance("AndroidKeyStore").apply {
                load(null)
                deleteEntry("dev.overalls.mila.device.${deployment.host}")
            }
        }
    }
}
