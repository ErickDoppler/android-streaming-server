plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.example.streamserver"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.example.streamserver"
        // Android 4.4+: the server/viewer revives very old tablets too.
        minSdk = 19
        targetSdk = 35
        versionCode = 14
        versionName = "1.4"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

// Deliberately no dependencies: modern androidx requires API 21+.
