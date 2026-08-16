plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.navbridge.app"
    // Explicit versions instead of flutter.* providers (stable on fresh builds).
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications requires core library desugaring.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.navbridge.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // GraphHopper needs Android 8+ (MethodHandle + java.time).
        minSdk = 26
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // R8 fails on JDK-only classes referenced by GraphHopper's
            // transitive deps (javax.activation / javax.imageio / xml.stream).
            // We want AOT speed, not shrinking — so no minify.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    // GraphHopper 7.0 pulls jakarta.xml.bind-api + jakarta.activation-api,
    // both shipping META-INF/NOTICE.md → merge conflict. Exclude them.
    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
            excludes += "/META-INF/NOTICE.md"
            excludes += "/META-INF/LICENSE.md"
            excludes += "/META-INF/DEPENDENCIES"
            excludes += "/META-INF/*.kotlin_module"
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

configurations.configureEach {
    // maplibre-android-sdk pulls in com.jakewharton.timber:timber, but the
    // Vietmap maps-sdk-android AAR (used by vietmap_flutter_navigation)
    // bundles the same timber.log.* classes → "Duplicate class timber.log.Timber".
    // Drop the standalone artifact; the copy bundled in the Vietmap AAR
    // satisfies maplibre's runtime need (timber's API is stable).
    exclude(group = "com.jakewharton.timber", module = "timber")
}

dependencies {
    // flutter_local_notifications requires core library desugaring.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // On-device offline routing (GraphHopper core, MIT, runs on Android).
    // 7.0 is the last line with classic setVehicle/setWeighting("fastest")
    // (no custom-model expression compilation → works on Android ART;
    // 8.x rejects fastest, 9.x/10.x need Janino or JDK 19+).
    implementation("com.graphhopper:graphhopper-core:7.0")
    implementation("org.slf4j:slf4j-nop:2.0.13")
    // NOTE: do NOT exclude timber here anymore. The old Vietmap navigation
    // SDK bundled Timber inside its AAR; that SDK is gone, so the transitive
    // `timber` from maplibre-android-sdk is the ONLY copy — excluding it
    // crashed MapView with `NoClassDefFoundError: timber.log.Timber`.
}

flutter {
    source = "../.."
}
