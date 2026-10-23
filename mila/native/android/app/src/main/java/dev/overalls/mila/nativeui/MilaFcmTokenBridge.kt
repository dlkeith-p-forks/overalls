package dev.overalls.mila.nativeui

/**
 * Host-facing bridge for FirebaseMessagingService (or another Android push provider).
 *
 * The native UI module intentionally has no Firebase dependency. The host's provider callback
 * forwards token rotations to [accept], which validates the token through the authenticated Rust
 * session before recording only the opaque provider id in the local projection. Token bytes never
 * enter UI state or logs.
 */
class MilaFcmTokenBridge(
    private val registration: MilaFcmRegistration,
    private val os: MilaNotificationOs,
) {
    /** Handles a provider token callback, including token deletion/null callbacks. */
    fun accept(token: String?): Boolean = registration.onToken(token, os)
}

