package dev.overalls.mila.nativeui

import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class MilaDeepLinksTest {
    @Test fun acceptsMachineTargetAndRejectsStaleGeneration() {
        val id = UUID.randomUUID()
        val controller = MilaDeepLinkController()
        val generation = controller.beginSession()
        assertTrue(controller.accept("overalls://mila/machines/$id", generation))
        assertEquals(MilaRoute.Machine(id), controller.target)
        assertFalse(controller.accept("overalls://mila/threads", generation - 1))
        assertEquals(MilaRoute.Machine(id), controller.target)
    }

    @Test fun malformedAndCommandLikeLinksDoNotChangeTarget() {
        val controller = MilaDeepLinkController()
        val generation = controller.beginSession()
        assertFalse(controller.accept("overalls://mila/machines/not-an-id", generation))
        assertFalse(controller.accept("overalls://mila/machines?command=rm", generation))
        assertEquals(MilaRoute.Machines, controller.target)
    }
}
