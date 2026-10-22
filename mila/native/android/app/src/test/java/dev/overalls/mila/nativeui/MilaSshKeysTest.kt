package dev.overalls.mila.nativeui
import org.junit.Assert.*
import org.junit.Test
private class Keys: MilaSshKeyStore { var values=mutableListOf(MilaSshKey("fp1","phone"), MilaSshKey("","bad")); override fun list()=values; override fun revoke(f:String):Boolean { val n=values.removeIf{it.fingerprint==f}; return n } }
class MilaSshKeysTest { @Test fun listsOnlyIdentifiedKeysAndRevokes(){ val k=Keys(); val c=MilaSshKeyController(k); assertEquals(1,c.keys.size); assertTrue(c.revoke("fp1")); assertTrue(c.keys.isEmpty()); assertFalse(c.revoke("missing")) } }
