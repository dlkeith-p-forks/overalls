package dev.overalls.mila.nativeui

/** Explicit sign-in/session state; credentials remain inside the Rust adapter. */
sealed interface MilaSignInState {
 data object SignedOut : MilaSignInState
 data class Connecting(val deployment: MilaDeployment) : MilaSignInState
 data class SignedIn(val deployment: MilaDeployment, val listing: MilaSessionListing, val approval: MilaApprovalState = MilaApprovalState.NotRequired) : MilaSignInState
 data class Failed(val deployment: MilaDeployment, val error: MilaFfiError) : MilaSignInState
}

class MilaSignInController(private val adapter: MilaFfiAdapter, private val store: MilaDeploymentStore? = null) {
 var state: MilaSignInState = MilaSignInState.SignedOut; private set
 suspend fun signIn(deployment: MilaDeployment) {
  store?.write(deployment)
  state = MilaSignInState.Connecting(deployment)
  state = when (val result = adapter.call(MilaFfiRequest(MilaFfiOperation.Bootstrap))) {
   is MilaFfiResult.Failure -> MilaSignInState.Failed(deployment, result.error)
   is MilaFfiResult.Success -> runCatching { MilaSessionListing.decode(result.response.payload.copyBytes()) }
    .fold({ MilaSignInState.SignedIn(deployment, it, store?.readApproval() ?: MilaApprovalState.NotRequired) }, { MilaSignInState.Failed(deployment, MilaFfiError.Unavailable) })
  }
 }
 suspend fun reconnect(): Boolean {
  val deployment = store?.read() ?: return false
  signIn(deployment)
  return state is MilaSignInState.SignedIn
 }
 fun setApproval(state: MilaApprovalState) {
  val signedIn = this.state as? MilaSignInState.SignedIn ?: return
  store?.writeApproval(state)
  this.state = signedIn.copy(approval = state)
 }
 fun signOut() { state = MilaSignInState.SignedOut }
}
