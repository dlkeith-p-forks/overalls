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

private class FakeRustBindings(
    private val version: Int = 1,
    private val route: String? = "overalls://machines",
) : MilaRustBindings {
    override fun abiVersion(): Int = version
    override fun canonicalRoute(value: String): String? = route
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
}
