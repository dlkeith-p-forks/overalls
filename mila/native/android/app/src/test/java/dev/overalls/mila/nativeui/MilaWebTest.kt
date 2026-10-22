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
}
