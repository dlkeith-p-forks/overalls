package dev.overalls.mila.nativeui
import org.junit.Assert.*
import org.junit.Test
private class Notifications: MilaNotificationStore { var xs=mutableListOf(MilaNotificationDevice("phone",false), MilaNotificationDevice("",true)); override fun list()=xs; override fun setEnabled(id:String,e:Boolean)=xs.indexOfFirst{it.id==id}.takeIf{it>=0}?.let{xs[it]=xs[it].copy(enabled=e);true}?:false; override fun remove(id:String)=xs.removeIf{it.id==id} }
class MilaNotificationsTest { @Test fun togglesAndRemovesTypedDevices(){ val n=Notifications(); val c=MilaNotificationController(n); assertEquals(1,c.devices.size); assertTrue(c.setEnabled("phone",true)); assertTrue(c.devices.single().enabled); assertTrue(c.remove("phone")); assertTrue(c.devices.isEmpty()); assertFalse(c.remove("missing")) } }

private class Provider(private val value: MilaNotificationProviderId?) : MilaNotificationProvider {
    override fun registrationId(): MilaNotificationProviderId? = value
}

private class Os(private val enabled: Boolean) : MilaNotificationOs {
    override fun notificationsEnabled(): Boolean = enabled
    override fun ensureChannel(channelId: String, name: String) = Unit
    override fun removeChannel(channelId: String) = Unit
}

class MilaNotificationRegistrationTest {
    @Test fun registrationRequiresOsPermissionAndProviderId() {
        val backing = object : MilaNotificationRegistrationStore {
            val values = mutableListOf<MilaNotificationDevice>()
            override fun list() = values.toList()
            override fun setEnabled(id: String, enabled: Boolean) = false
            override fun remove(id: String) = false
            override fun register(id: String, enabled: Boolean): Boolean { values += MilaNotificationDevice(id, enabled); return true }
        }
        val controller = MilaNotificationController(backing)
        assertFalse(controller.register(Provider(MilaNotificationProviderId.parse("token")!!), Os(false)))
        assertFalse(controller.register(Provider(null), Os(true)))
        assertTrue(controller.devices.isEmpty())
    }

    @Test fun registrationPersistsProviderIdentifierOnlyAfterOsPermission() {
        val backing = object : MilaNotificationRegistrationStore {
            val values = mutableListOf<MilaNotificationDevice>()
            override fun list() = values.toList()
            override fun setEnabled(id: String, enabled: Boolean) = false
            override fun remove(id: String) = false
            override fun register(id: String, enabled: Boolean): Boolean { values += MilaNotificationDevice(id, enabled); return true }
        }
        val controller = MilaNotificationController(backing)
        assertTrue(controller.register(Provider(MilaNotificationProviderId.parse("provider-id")!!), Os(true)))
        assertEquals(listOf(MilaNotificationDevice("provider-id", true)), controller.devices)
    }

    @Test fun providerIdentifierRejectsControlCharacters() {
        assertNull(MilaNotificationProviderId.parse("token\n"))
        assertNull(MilaNotificationProviderId.parse(""))
        assertEquals("token", MilaNotificationProviderId.parse("token")?.value)
    }
}
