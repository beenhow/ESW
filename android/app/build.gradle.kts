plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.exam.esw"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    lint {
        checkReleaseBuilds = false
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.exam.esw"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // R8 压缩在含 CameraX + ML Kit 的包上会触发 JVM OOM，改为只做 dex 不做全局压缩
            isMinifyEnabled = false
            isShrinkResources = false
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    packaging {
        jniLibs {
            // .so 在 APK 内参与压缩（安装时由系统解压），可把包体从 ~148MB 降到 ~87MB；
            // 运行时行为、ABI 覆盖与功能均不变。
            useLegacyPackaging = true
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // 扫描文档：Google ML Kit 文字识别（bundled 版，模型随 APK 打包，无需 GMS/联网）
    implementation("com.google.mlkit:text-recognition:16.0.1")
    // 扫描文档：读取拍照图片的 EXIF 旋转信息，供边界校正时摆正图片
    implementation("androidx.exifinterface:exifinterface:1.4.2")
}

