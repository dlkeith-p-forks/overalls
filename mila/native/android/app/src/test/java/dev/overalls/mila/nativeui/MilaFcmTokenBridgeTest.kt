package dev.overalls.mila.nativeui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MilaFcmTokenBridgeTest {
    @Test
    fun forwardsRotationsOnlyWhenPermissionAndRustValidationSucceed() {
        val store = object : MilaNotificationRegistrationStore {
            private val values = mutableListOf<MilaNotificationDevice>()
            override fun list() = values.toList()
            override fun setEnabled(id: String, enabled: Boolean) = false
            override fun remove(id: String) = false
            override fun register(id: String, enabled: Boolean): Boolean {
                values += MilaNotificationDevice(id, enabled)
                return true
            }
        }
        val adapter = object : MilaFfiAdapter {
            override suspend fun call(request: MilaFfiRequest) = MilaFfiResult.Failure(MilaFfiError.Unavailable)
            override fun validatePushRegistration(token: String, appId: String, deployment: String, endpoint: String?) =
                if (token == "rotated" && appId == "mila" && deployment == "host") Result.success(Unit)
                else Result.failure(IllegalArgumentException("rejected"))
        }
        val controller = MilaAuthenticatedNotificationController(adapter, store, "mila", "host")
        val bridge = MilaFcmTokenBridge(MilaFcmRegistration(controller), object : MilaNotificationOs {
            override fun notificationsEnabled() = true
            override fun ensureChannel(channelId: String, name: String) = Unit
            override fun removeChannel(channelId: String) = Unit
        })

        assertFalse(bridge.accept(null))
        assertFalse(bridge.accept("rejected"))
        assertTrue(bridge.accept("rotated"))
        assertTrue(controller.devices.any { it.id == "rotated" })
    }
}

