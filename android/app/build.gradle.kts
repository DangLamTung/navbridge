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

dependencies {
    // On-device offline routing (GraphHopper core, MIT, runs on Android).
    // 7.0 is the last line with classic setVehicle/setWeighting("fastest")
    // (no custom-model expression compilation → works on Android ART;
    // 8.x rejects fastest, 9.x/10.x need Janino or JDK 19+).
    implementation("com.graphhopper:graphhopper-core:7.0")
    implementation("org.slf4j:slf4j-nop:2.0.13")
}

flutter {
    source = "../.."
}
