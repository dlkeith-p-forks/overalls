plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.overalls.mila"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.overalls.mila"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // FCM configuration comes from Gradle properties (`-Pmila.fcm.projectId=…`
        // or ~/.gradle/gradle.properties), never from a committed
        // google-services.json. Absent values build an app without push.
        for ((field, property) in listOf(
            "MILA_FCM_PROJECT_ID" to "mila.fcm.projectId",
            "MILA_FCM_APPLICATION_ID" to "mila.fcm.applicationId",
            "MILA_FCM_API_KEY" to "mila.fcm.apiKey",
            "MILA_FCM_SENDER_ID" to "mila.fcm.senderId",
        )) {
            val value = (project.findProperty(property) as String?) ?: ""
            require(value.all { it.isLetterOrDigit() || it in ":-_." }) { "$property has unexpected characters" }
            buildConfigField("String", field, "\"$value\"")
        }
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Push delivery only; no analytics. The BoM pins every Firebase artifact.
    implementation(platform("com.google.firebase:firebase-bom:33.7.0"))
    implementation("com.google.firebase:firebase-messaging")
    // X25519, HKDF-SHA256 and ChaCha20-Poly1305 for E2E pokes on every API level.
    implementation("org.bouncycastle:bcprov-jdk18on:1.79")
    testImplementation("junit:junit:4.13.2")
}
