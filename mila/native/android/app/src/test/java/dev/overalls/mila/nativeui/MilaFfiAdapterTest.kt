package dev.overalls.mila.nativeui

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MilaFfiAdapterTest {
    @Test
    fun payloadCopiesInputAndOutput() {
        val input = byteArrayOf(1, 2, 3)
        val payload = MilaFfiPayload(input)
        input[0] = 9

        val output = payload.copyBytes()
        output[1] = 8

        assertArrayEquals(byteArrayOf(1, 2, 3), payload.copyBytes())
    }

    @Test
    fun unavailableAdapterFailsWithoutLeakingPayload() = runBlocking {
        val request = MilaFfiRequest(
            operation = MilaFfiOperation.Bootstrap,
            payload = MilaFfiPayload(byteArrayOf(4, 5)),
        )

        val result = UnavailableMilaFfiAdapter.call(request)

        assertEquals(MilaFfiResult.Failure(MilaFfiError.Unavailable), result)
    }

    @Test
    fun linkedAdapterReportsUnavailableWhenNativeLibraryIsAbsent() = runBlocking {
        val result = LinkedMilaFfiAdapter().call(MilaFfiRequest(MilaFfiOperation.Refresh))

        assertTrue(result is MilaFfiResult.Failure)
        assertEquals(MilaFfiError.Unavailable, (result as MilaFfiResult.Failure).error)
    }
}

class MilaSessionRefresherTest {
    @Test
    fun refreshPublishesTypedListing() = runBlocking {
        val listing = "{\"machines\":[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"demo\",\"status\":\"running\"}],\"has_more\":false}"
        val adapter = object : MilaFfiAdapter {
            override suspend fun call(request: MilaFfiRequest): MilaFfiResult = MilaFfiResult.Success(
                MilaFfiResponse(MilaFfiPayload(listing.toByteArray()))
            )
        }
        val state = MilaSessionRefresher.refresh(adapter)
        assertEquals("demo", (state as MilaSessionConnection.Connected).listing.machines.single().name)
    }

    @Test
    fun malformedListingFailsClosed() = runBlocking {
        val adapter = object : MilaFfiAdapter {
            override suspend fun call(request: MilaFfiRequest): MilaFfiResult = MilaFfiResult.Success(
                MilaFfiResponse(MilaFfiPayload("not-json".toByteArray()))
            )
        }
        assertTrue(MilaSessionRefresher.refresh(adapter) is MilaSessionConnection.Failed)
    }
}

private class FakeRustBindings(
    private val version: Int = 1,
    private val route: String? = "overalls://machines",
    private val actions: Int? = 5,
) : MilaRustBindings {
    override fun abiVersion(): Int = version
    override fun canonicalRoute(value: String): String? = route
    override fun machineActions(snapshot: ByteArray, host: String, port: Int?, index: Int): Int? = actions
    override fun sessionConnect(trust: ByteArray, host: String, publicKey: String, port: Int, timeoutMs: Int, signer: MilaDeviceKey): MilaSessionHandle? = null
    override fun threadCommandKind(value: String): Int = 1
    override fun machineCommandKind(value: String): Int = 10
    override fun terminalAttach(from: Long, columns: Int, rows: Int, readWrite: Boolean): Int = 0
    override fun terminalInput(length: Int, readWrite: Boolean): Int = 0
    override fun terminalResize(columns: Int, rows: Int, readWrite: Boolean): Int = 0
}

class MilaLinkedFfiAdapterTest {
    @Test
    fun linkedAdapterUsesTypedRustBindings() = runBlocking {
        val adapter = LinkedMilaFfiAdapter(FakeRustBindings())
        val payload = MilaFfiPayload(byteArrayOf(7, 8))
        val result = adapter.call(MilaFfiRequest(MilaFfiOperation.Bootstrap, payload))
        assertEquals(MilaFfiResult.Success(MilaFfiResponse(payload)), result)
    }

    @Test
    fun linkedAdapterRejectsIncompatibleAbi() = runBlocking {
        val result = LinkedMilaFfiAdapter(FakeRustBindings(version = 2))
            .call(MilaFfiRequest(MilaFfiOperation.Refresh))
        assertEquals(MilaFfiResult.Failure(MilaFfiError.IncompatibleAbi), result)
    }

    @Test
    fun canonicalRouteReturnsNativeResult() {
        val adapter = LinkedMilaFfiAdapter(FakeRustBindings(route = "overalls://threads"))
        assertEquals(Result.success("overalls://threads"), adapter.canonicalizeRoute("overalls://threads"))
    }

    @Test
    fun canonicalRouteRejectsNativeNull() {
        val adapter = LinkedMilaFfiAdapter(FakeRustBindings(route = null))
        assertTrue(adapter.canonicalizeRoute("bad").isFailure)
    }

    @Test
    fun machineActionsExposeOnlyRustPolicyBits() {
        val adapter = LinkedMilaFfiAdapter(FakeRustBindings(actions = 9))
        assertEquals(Result.success(9), adapter.machineActions(byteArrayOf(1), "mgmt.example.test", 443, 0))
    }

    @Test
    fun machineActionsRejectInvalidSnapshot() {
        val adapter = LinkedMilaFfiAdapter(FakeRustBindings(actions = null))
        assertTrue(adapter.machineActions(byteArrayOf(1), "mgmt.example.test", null, 0).isFailure)
    }

    @Test
    fun threadCommandKindUsesClosedRustTags() {
        val adapter = LinkedMilaFfiAdapter(FakeRustBindings())
        assertEquals(Result.success(MilaThreadCommand.List), adapter.threadCommandKind("thread ls"))
    }

    @Test
    fun machineCommandKindUsesClosedRustTags() {
        val adapter = LinkedMilaFfiAdapter(FakeRustBindings())
        assertEquals(Result.success(MilaMachineCommand.ShareAdd), adapter.machineCommandKind("machine share add"))
    }

    @Test
    fun machineCommandPaletteCoversClosedRustCatalog() {
        assertEquals(
            listOf(
                "ls", "show", "new", "resize", "start", "stop", "pause", "resume", "rm",
                "share add", "share remove", "web show", "web set",
            ),
            machineCommandChoices.map { it.command },
        )
        assertEquals(MilaMachineCommand.entries.size, machineCommandChoices.size)
    }

    @Test
    fun threadCommandPaletteCoversClosedRustCatalog() {
        assertEquals(
            listOf(
                "thread ls", "thread show", "thread turns", "thread prompt", "thread answer",
                "thread plan approve", "thread plan revise", "thread mode", "thread read",
            ),
            threadCommandChoices.map { it.second },
        )
        assertEquals(MilaThreadCommand.entries.size, threadCommandChoices.size)
    }
}

class MilaAppLockTest {
    private class Store : MilaAppLockStore {
        var value: MilaAppLockState? = null
        override fun read(): MilaAppLockState? = value
        override fun write(state: MilaAppLockState) { value = state }
    }

    @Test fun staleAuthenticationNeverUnlocks() {
        val c = MilaAppLockController(Store(), MilaAppLockState(true, MilaLockDelay.Immediate))
        c.setAvailability(MilaLockAvailability.Available)
        val token = c.requestUnlock()!!
        c.finishUnlock(token + 1u, true)
        assertEquals(MilaLockPhase.Authenticating, c.state.phase)
        c.finishUnlock(token, true)
        assertEquals(MilaLockPhase.Unlocked, c.state.phase)
    }

    @Test fun delayedBackgroundRelocksOnlyAfterDelay() {
        val c = MilaAppLockController(Store(), MilaAppLockState(true, MilaLockDelay.OneMinute))
        c.setAvailability(MilaLockAvailability.Available)
        val token = c.requestUnlock()!!; c.finishUnlock(token, true)
        c.onBackground(1000)
        c.onForeground(60_999)
        assertEquals(MilaLockPhase.Unlocked, c.state.phase)
        c.onBackground(1000); c.onForeground(61_000)
        assertEquals(MilaLockPhase.Locked, c.state.phase)
    }

    @Test fun unavailableFailOpenIsExplicitAndDisablesObscuring() {
        val c = MilaAppLockController(Store(), MilaAppLockState(true, MilaLockDelay.Immediate))
        c.setAvailability(MilaLockAvailability.Unavailable)
        assertEquals(MilaLockPhase.Unlocked, c.state.phase)
        assertTrue(!c.state.obscured)
    }
}
