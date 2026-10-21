package dev.overalls.mila.nativeui

import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MilaRouteParserTest {
    @Test
    fun acceptsNavigationRoutesAndRejectsAmbiguousInput() {
        val id = "123e4567-e89b-12d3-a456-426614174000"

        assertEquals(MilaRoute.Machines, parseMilaRoute("overalls://machines"))
        assertEquals(MilaRoute.Machine(UUID.fromString(id)), parseMilaRoute("overalls://machines/$id"))
        assertNull(parseMilaRoute("overalls://machines/$id?debug=true"))
        assertNull(parseMilaRoute("overalls://machines/%2F$id"))
    }

    @Test
    fun invokesRustJniRouteCanonicalization() {
        assertEquals("overalls://machines", MilaRustFfi.canonicalRoute("overalls://machines"))
        assertNull(MilaRustFfi.canonicalRoute("overalls://machines?command=bad"))
        assertEquals(1, MilaRustFfi.abiVersion())
    }
}
