package dev.overalls.mila.nativeui

import org.junit.Assert.assertEquals
import org.junit.Test

class MilaSessionListingTest {
    @Test fun decodesBoundedValidatedRows() {
        val listing = MilaSessionListing.decode("{\"machines\":[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"build\",\"status\":\"running\"}],\"has_more\":true}".toByteArray())
        assertEquals("build", listing.machines.single().name)
        assertEquals(true, listing.hasMore)
    }
    @Test(expected = IllegalArgumentException::class) fun rejectsMalformedRows() {
        MilaSessionListing.decode("{\"machines\":[{\"id\":\"bad\"}]}".toByteArray())
    }
}
