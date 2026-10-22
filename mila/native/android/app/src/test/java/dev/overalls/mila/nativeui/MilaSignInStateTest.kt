package dev.overalls.mila.nativeui
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
private class SignInAdapter(private val result: MilaFfiResult): MilaFfiAdapter { override suspend fun call(request: MilaFfiRequest)=result }
class MilaSignInStateTest {
 @Test fun sessionConnectConfigRejectsMissingTrustAndKey() {
  assertThrows(IllegalArgumentException::class.java) { MilaSessionConnectConfig(byteArrayOf(), "ssh-key") }
  assertThrows(IllegalArgumentException::class.java) { MilaSessionConnectConfig(byteArrayOf(1), "") }
 }

 @Test fun successfulBootstrapProducesSignedInListing() = runBlocking {
  val payload = MilaFfiPayload("{\"machines\":[],\"has_more\":false}".toByteArray())
  val d=MilaDeployment("mila.example"); val c=MilaSignInController(SignInAdapter(MilaFfiResult.Success(MilaFfiResponse(payload))))
  c.signIn(d); assertEquals(MilaSignInState.SignedIn(d, MilaSessionListing(emptyList(),false)), c.state)
 }
 @Test fun failedBootstrapRetainsDeploymentAndError() = runBlocking {
  val d=MilaDeployment("mila.example"); val c=MilaSignInController(SignInAdapter(MilaFfiResult.Failure(MilaFfiError.Unavailable)))
  c.signIn(d); assertEquals(MilaSignInState.Failed(d,MilaFfiError.Unavailable), c.state)
 }
}
