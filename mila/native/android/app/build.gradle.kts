plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "dev.overalls.mila.nativeui"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.overalls.mila.nativeui"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }


    buildFeatures {
        compose = true
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.12.00")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.activity:activity-compose:1.12.0")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    debugImplementation("androidx.compose.ui:ui-tooling")

    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}

android {
    testOptions {
        unitTests.isIncludeAndroidResources = true
    }
}

// Build and package the real Rust JNI library for every Android ABI.
val rustTargetByAbi = mapOf(
    "arm64-v8a" to "aarch64-linux-android",
    "armeabi-v7a" to "armv7-linux-androideabi",
    "x86_64" to "x86_64-linux-android",
)

android.defaultConfig.ndk { abiFilters += rustTargetByAbi.keys }

tasks.register("buildRustJni") {
    val outputRoot = layout.buildDirectory.dir("rust-jni")
    outputs.dir(outputRoot)
    doLast {
        val root = rootProject.projectDir.toPath().resolve("../../../rust").normalize()
        val ndkHome = System.getenv("ANDROID_NDK_HOME") ?: error("ANDROID_NDK_HOME is required")
        rustTargetByAbi.forEach { (abi, target) ->
            exec { commandLine("cargo", "ndk", "-t", target, "-o", outputRoot.get().asFile.absolutePath, "build", "--release", "-p", "mila-ffi"); environment("ANDROID_NDK_HOME", ndkHome); workingDir(root.toFile()) }
            val source = outputRoot.get().asFile.resolve("$abi/libmila_ffi.so")
            val destination = project.file("src/main/jniLibs/$abi/libmila_ffi.so")
            destination.parentFile.mkdirs()
            source.copyTo(destination, overwrite = true)
        }
    }
}
tasks.named("preBuild") { dependsOn("buildRustJni") }
