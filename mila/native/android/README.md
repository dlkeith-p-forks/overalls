# Mila Android native UI scaffold

This is an isolated Jetpack Compose application for the native Mila presentation seam. It does not
change the Flutter Android runner or link a Rust library yet. A host app can copy the Compose
surface and inject a generated adapter implementing `MilaFfiAdapter`.

The project metadata targets Android API 36, uses Java 17, Android Gradle Plugin 9.1.0, and Kotlin
2.4.0 with the Kotlin Compose compiler plugin. The Compose dependency BOM is pinned in
`app/build.gradle.kts`; update it together with the rest of the native dependency lock when the
host build adopts this scaffold.

`MilaFfiPayload` owns a defensive copy of every byte array. Replace
`UnavailableMilaFfiAdapter` with generated Rust bindings at the host integration boundary. Keep
credentials, key material, authentication tokens, and terminal bytes out of this adapter's logs and
UI state.

## Static validation

On a machine with Android SDK API 36, JDK 17, and Gradle 9:

```sh
gradle --project-dir mila/native/android :app:assembleDebug
```

The repository's Linux checks do not install a native Android SDK for this standalone scaffold. If
Gradle or the SDK is unavailable, inspect the Kotlin and Gradle metadata and run the contract syntax
check from the repository root.
