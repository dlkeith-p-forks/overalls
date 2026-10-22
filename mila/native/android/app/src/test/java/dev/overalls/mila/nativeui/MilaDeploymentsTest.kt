package dev.overalls.mila.nativeui

import org.junit.Assert.*
import org.junit.Test

class MilaDeploymentsTest {
 @Test fun selectionDeduplicatesAndSelectsKnownHost() {
  val model = MilaDeploymentSelection(listOf(MilaDeployment("mila.example"), MilaDeployment("mila.example")))
  assertEquals(1, model.deployments.size)
  assertTrue(model.select("mila.example"))
  assertFalse(model.select("other.example"))
 }
 @Test(expected = IllegalArgumentException::class) fun invalidHostRejected() { MilaDeployment("localhost") }
 @Test(expected = IllegalArgumentException::class) fun invalidPortRejected() { MilaDeployment("mila.example", 70000) }
}
