package dev.overalls.mila.nativeui
import org.junit.Assert.*
import org.junit.Test
private class Notifications: MilaNotificationStore { var xs=mutableListOf(MilaNotificationDevice("phone",false), MilaNotificationDevice("",true)); override fun list()=xs; override fun setEnabled(id:String,e:Boolean)=xs.indexOfFirst{it.id==id}.takeIf{it>=0}?.let{xs[it]=xs[it].copy(enabled=e);true}?:false; override fun remove(id:String)=xs.removeIf{it.id==id} }
class MilaNotificationsTest { @Test fun togglesAndRemovesTypedDevices(){ val n=Notifications(); val c=MilaNotificationController(n); assertEquals(1,c.devices.size); assertTrue(c.setEnabled("phone",true)); assertTrue(c.devices.single().enabled); assertTrue(c.remove("phone")); assertTrue(c.devices.isEmpty()); assertFalse(c.remove("missing")) } }
