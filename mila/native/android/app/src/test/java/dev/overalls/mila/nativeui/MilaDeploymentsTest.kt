package dev.overalls.mila.nativeui

import org.junit.Assert.*
import org.junit.Test

class MilaDeploymentsTest {
 @Test fun userHostIsCanonicalizedBeforePersistence(){
  val deployment = parseMilaDeploymentHost("  Overalls.Example:8443 ").getOrThrow()
  assertEquals("overalls.example", deployment.host)
  assertEquals(8443, deployment.port)
 }
 @Test fun malformedUserHostNeverCreatesDeployment(){
  assertTrue(parseMilaDeploymentHost("localhost").isFailure)
  assertTrue(parseMilaDeploymentHost("overalls.example:0").isFailure)
  assertTrue(parseMilaDeploymentHost("overalls.example:65536").isFailure)
  assertTrue(parseMilaDeploymentHost("overalls.example:8443:22").isFailure)
 }
 @Test fun selectionDeduplicatesAndSelectsKnownHost() {
  val model = MilaDeploymentSelection(listOf(MilaDeployment("mila.example"), MilaDeployment("mila.example")))
  assertEquals(1, model.deployments.size)
  assertTrue(model.select("mila.example"))
  assertFalse(model.select("other.example"))
 }
 @Test(expected = IllegalArgumentException::class) fun invalidHostRejected() { MilaDeployment("localhost") }
 @Test(expected = IllegalArgumentException::class) fun invalidPortRejected() { MilaDeployment("mila.example", 70000) }
}
