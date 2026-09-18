import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Signing material is optional. android/key.properties is gitignored, so its
// absence is the normal case — in CI and on a fresh clone alike.
val keystoreProperties: Properties? = rootProject
    .file("key.properties")
    .takeIf { it.exists() }
    ?.let { file -> Properties().apply { file.inputStream().use(::load) } }

android {
    namespace = "my.wzbgroup.osint_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "my.wzbgroup.osint_app"
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
        // Only declared when a keystore is actually present. Without one the
        // release build stays unsigned rather than falling back to the debug
        // key — a debug-signed APK looks releasable and is not, and every
        // machine's debug key differs, so updates would refuse to install
        // over each other.
        if (keystoreProperties != null) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")
                    ?.let { rootProject.file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // Null signing config makes Gradle emit an unsigned APK, which is
            // what CI wants: no secret has to live in the repository or in
            // Actions, and whoever releases signs the artifact themselves.
            // Drop an android/key.properties in place to sign locally.
            signingConfig = keystoreProperties?.let {
                signingConfigs.getByName("release")
            }

            // R8 needs the rules in proguard-rules.pro: the ML Kit text
            // plugin references recogniser classes for scripts this app does
            // not depend on, and without them the release build fails.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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
