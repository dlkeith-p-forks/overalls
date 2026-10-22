package dev.overalls.mila.nativeui

/** Generation-safe target routing for external Android intents. */
class MilaDeepLinkController {
    var target: MilaRoute = MilaRoute.Machines
        private set
    private var generation: Long = 0

    fun accept(uri: String, expectedGeneration: Long = generation): Boolean {
        if (expectedGeneration != generation) return false
        val route = parseMilaRoute(uri) ?: return false
        target = route
        return true
    }

    fun beginSession(): Long {
        generation += 1
        target = MilaRoute.Machines
        return generation
    }
}
