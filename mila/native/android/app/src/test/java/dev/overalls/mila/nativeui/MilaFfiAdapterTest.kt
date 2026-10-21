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
