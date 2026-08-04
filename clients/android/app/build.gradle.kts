import org.gradle.api.GradleException
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.nio.charset.StandardCharsets

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "app.dayflow.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "app.dayflow.android"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildFeatures {
        compose = true
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_21)
        }
    }

    sourceSets.getByName("main") {
        java.srcDir("../../generated/kotlin")
        kotlin.srcDir("../../generated/kotlin")
        jniLibs.srcDir("../../generated/android/jniLibs")
    }
}

val dayflowCoreJniLibs = file("../../generated/android/jniLibs")
val expectedDayflowCoreAbis = listOf("arm64-v8a", "armeabi-v7a", "x86_64")
val requiredDayflowCoreSymbols = listOf(
    "uniffi_dayflow_core_fn_func_canonical_device_request",
)

tasks.register("verifyDayflowCoreNative") {
    doLast {
        val missing = expectedDayflowCoreAbis.filter { abi ->
            val library = file("$dayflowCoreJniLibs/$abi/libdayflow_core.so")
            if (!library.isFile) {
                true
            } else {
                val binary = String(library.readBytes(), StandardCharsets.ISO_8859_1)
                requiredDayflowCoreSymbols.any { symbol -> !binary.contains(symbol) }
            }
        }
        if (missing.isNotEmpty()) {
            throw GradleException(
                "Missing or stale Dayflow Rust libraries for ABI(s): ${missing.joinToString()}. " +
                    "Run scripts/build_dayflow_core_android.sh with an Android NDK before assembling the app.",
            )
        }
    }
}

tasks.named("preBuild") {
    dependsOn("verifyDayflowCoreNative")
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2026.06.01"))
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.10.0")
    implementation("androidx.core:core-ktx:1.18.0")
    implementation("androidx.window:window:1.5.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("net.java.dev.jna:jna:5.19.1@aar")

    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.jetbrains.kotlin:kotlin-test-junit:2.4.10")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}
