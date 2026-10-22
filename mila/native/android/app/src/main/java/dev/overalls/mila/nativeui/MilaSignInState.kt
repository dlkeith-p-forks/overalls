package dev.overalls.mila.nativeui

/** Explicit sign-in/session state; credentials remain inside the Rust adapter. */
sealed interface MilaSignInState {
 data object SignedOut : MilaSignInState
 data class Connecting(val deployment: MilaDeployment) : MilaSignInState
 data class SignedIn(val deployment: MilaDeployment, val listing: MilaSessionListing, val approval: MilaApprovalState = MilaApprovalState.NotRequired) : MilaSignInState
 data class Failed(val deployment: MilaDeployment, val error: MilaFfiError) : MilaSignInState
}

class MilaSignInController(private val adapter: MilaFfiAdapter, private val store: MilaDeploymentStore? = null) : AutoCloseable {
 var state: MilaSignInState = MilaSignInState.SignedOut; private set

 /**
  * Establishes the real certificate-authenticated Rust session. Trust bytes and the signer
  * remain in the native boundary; the controller only publishes the validated listing.
  */
 suspend fun signIn(deployment: MilaDeployment, config: MilaSessionConnectConfig, signer: MilaDeviceKey) {
  store?.write(deployment)
  // A new attempt owns the adapter's session. Release a previous attempt before
  // connecting so a refused reconnect cannot leave the old authenticated channel live.
  (adapter as? MilaSessionConnector)?.bindSession(null)
  state = MilaSignInState.Connecting(deployment)
  val connector = adapter as? MilaSessionConnector
  val session = runCatching {
   require(connector != null) { "native session connector unavailable" }
   connector.connect(deployment, config, signer) ?: error("session connection refused")
  }.getOrNull()
  if (session == null) {
   state = MilaSignInState.Failed(deployment, MilaFfiError.Unavailable)
   return
  }
  val listing = runCatching {
   session.readMachines()
   MilaSessionListing.decode(session.listing())
  }.getOrNull()
  if (listing == null) {
   session.close()
   state = MilaSignInState.Failed(deployment, MilaFfiError.Unavailable)
  } else {
   connector?.bindSession(session)
   state = MilaSignInState.SignedIn(deployment, listing, store?.readApproval() ?: MilaApprovalState.NotRequired)
  }
 }
 suspend fun signIn(deployment: MilaDeployment) {
  store?.write(deployment)
  (adapter as? MilaSessionConnector)?.bindSession(null)
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
 /**
  * @cc [owner:ghuntley,label:security] mila-android-session-close
  * Closing an Android sign-in controller MUST release its adapter-owned authenticated session and
  * MUST retain the validated deployment selection so a later controller can reconnect without
  * retaining credentials in UI state.
  */
 fun signOut() {
  (adapter as? MilaSessionConnector)?.bindSession(null)
  state = MilaSignInState.SignedOut
 }

 override fun close() = signOut()
}
