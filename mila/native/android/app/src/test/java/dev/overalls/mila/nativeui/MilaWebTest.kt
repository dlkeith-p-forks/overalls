package dev.overalls.mila.nativeui

import org.junit.Assert.*
import org.junit.Test

class MilaWebTest {
 @Test fun parsesSafeEndpoint() {
  val result = parseMilaWebEndpoint("{\"machine_id\":\"00000000-0000-0000-0000-000000000001\",\"port\":8080,\"visibility\":\"public\",\"policy_revision\":2,\"url\":\"https://box.example.test\"}")
  assertTrue(result.isSuccess); assertEquals(8080, result.getOrThrow().port)
 }
 @Test fun rejectsUnsafeUrl() {
  val result = parseMilaWebEndpoint("{\"machine_id\":\"00000000-0000-0000-0000-000000000001\",\"port\":8080,\"visibility\":\"public\",\"policy_revision\":2,\"url\":\"javascript:alert(1)\"}")
  assertTrue(result.isFailure)
 }
 @Test fun rejectsInvalidPortAndVisibility() {
  val result = parseMilaWebEndpoint("{\"machine_id\":\"00000000-0000-0000-0000-000000000001\",\"port\":0,\"visibility\":\"public\",\"policy_revision\":2}")
  assertTrue(result.isFailure)
 }
 @Test fun controllerRejectsEndpointForAnotherMachine() = kotlinx.coroutines.runBlocking {
  val foreign = java.util.UUID.fromString("00000000-0000-0000-0000-000000000002")
  val adapter = object : MilaFfiAdapter {
   override suspend fun call(request: MilaFfiRequest) = MilaFfiResult.Failure(MilaFfiError.Unavailable)
   override suspend fun webShow(machineId: java.util.UUID) = Result.success("{\"machine_id\":\"$foreign\",\"port\":8080,\"visibility\":\"public\",\"policy_revision\":2}")
  }
  val controller = MilaWebController(adapter)
  assertFalse(controller.show(java.util.UUID.fromString("00000000-0000-0000-0000-000000000001")))
  assertNull(controller.endpoint)
 }
 @Test fun setRequiresLoadedRevisionAndUsesIt() = kotlinx.coroutines.runBlocking {
  val id = java.util.UUID.fromString("00000000-0000-0000-0000-000000000001")
  var revision = -1L
  val adapter = object : MilaFfiAdapter {
   override suspend fun call(request: MilaFfiRequest) = MilaFfiResult.Failure(MilaFfiError.Unavailable)
   override suspend fun webShow(machineId: java.util.UUID) = Result.success("{\"machine_id\":\"$id\",\"port\":8080,\"visibility\":\"public\",\"policy_revision\":7}")
   override suspend fun webSet(machineId: java.util.UUID, port: Int, public: Boolean, requestRevision: Long) { revision = requestRevision; }
  }
  val controller = MilaWebController(adapter)
  assertFalse(controller.set(id, 8081, false))
  assertTrue(controller.show(id))
  assertTrue(controller.set(id, 8081, false))
  assertEquals(7L, revision)
 }
}
