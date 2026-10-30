import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
val allowDevelopmentSigning =
    providers.gradleProperty("allowDevelopmentSigning").orNull == "true"

android {
    namespace = "com.thenex.nex_gallery"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    lint {
        // Flutter regenerates this ignored machine-local file on Windows using
        // a path representation that the PropertyEscape rule rejects.
        lintConfig = rootProject.file("lint.xml")
    }

    packaging {
        // Compressed native libraries keep the download small: ONNX Runtime
        // alone is 28.6 MB uncompressed on ARM64. Android extracts them once
        // at install time.
        jniLibs {
            useLegacyPackaging = true
        }
        resources {
            excludes += listOf(
                "META-INF/DEPENDENCIES*",
                "META-INF/LICENSE*",
                "META-INF/NOTICE*",
                "META-INF/*.kotlin_module",
                "DebugProbesKt.bin",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.thenex.nex_gallery"
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
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            // Development signing is opt-in so a missing release key cannot
            // silently produce an artifact that looks publishable.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else if (allowDevelopmentSigning) {
                signingConfigs.getByName("debug")
            } else {
                null
            }
        }
    }
}

// Keep project sync, debug builds and debug lint usable without a release key,
// while still failing closed before any unsigned release work starts.
if (!keystorePropertiesFile.exists() && !allowDevelopmentSigning) {
    tasks.configureEach {
        if (name == "preReleaseBuild") {
            doFirst {
                throw GradleException(
                    "Release signing is not configured. Add android/key.properties " +
                        "or explicitly pass -PallowDevelopmentSigning=true for a " +
                        "non-publishable verification build.",
                )
            }
        }
    }
}

// Release builds target ARM phones only (plan §2). Plugins such as ONNX
// Runtime still ship x86/x86_64 libraries, 12 MB of dead weight without a
// matching Flutter engine. Debug builds keep them for the x64 emulator.
androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        variant.packaging.jniLibs.excludes.addAll(listOf("lib/x86/**", "lib/x86_64/**"))
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
    // Match the Media3 version used by video_player_android.
    implementation("androidx.media3:media3-transformer:1.9.2")
    implementation("androidx.media3:media3-effect:1.9.2")
    // Camera QR scanning for PC pairing; ZXing only, no Google services.
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    implementation("androidx.work:work-runtime-ktx:2.12.0")
    // Media3/WorkManager's older transitive Guava predates CVE-2026-102554.
    implementation("com.google.guava:guava:33.7.2-android")
}
