package dev.overalls.mila.nativeui

import org.junit.Assert.*
import org.junit.Test

private class MemoryDeploymentStore : MilaDeploymentStore {
    var value: MilaDeployment? = null
    override fun read() = value
    override fun write(deployment: MilaDeployment) { value = deployment }
    override fun clear() { value = null }
}

class MilaDeploymentPersistenceTest {
    @Test fun signInPersistsDeploymentAndReconnects() = kotlinx.coroutines.runBlocking {
        val store = MemoryDeploymentStore()
        val deployment = MilaDeployment("mila.example", 443)
        val result = MilaFfiResult.Success(MilaFfiResponse(MilaFfiPayload("{\"machines\":[],\"has_more\":false}".toByteArray())))
        val controller = MilaSignInController(object : MilaFfiAdapter { override suspend fun call(request: MilaFfiRequest) = result }, store)
        controller.signIn(deployment)
        assertEquals(deployment, store.read())
        val reconnected = MilaSignInController(object : MilaFfiAdapter { override suspend fun call(request: MilaFfiRequest) = result }, store)
        assertTrue(reconnected.reconnect())
        assertEquals(MilaSignInState.SignedIn(deployment, MilaSessionListing(emptyList(), false)), reconnected.state)
    }

    @Test fun malformedPersistedSelectionIsDiscardedByPlatformStoreContract() {
        val store = MemoryDeploymentStore()
        assertNull(store.read())
        store.write(MilaDeployment("mila.example"))
        assertEquals("mila.example", store.read()?.host)
        store.clear()
        assertNull(store.read())
    }
}
