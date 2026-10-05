import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.nexora.license_admin"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.nexora.license_admin"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                storeType = keystoreProperties.getProperty("storeType", "PKCS12")
            }
        }
    }

    buildTypes {
        release {
            // ══ توقيع ثابت إلزامي ══
            // كان التوقيع بمفتاح debug: كل تشغيل CI يولّد مفتاحاً جديداً
            // ⇒ توقيع كل إصدار يخالف المثبَّت قبله ⇒ أندرويد يرفض التحديث
            // (INSTALL_FAILED_UPDATE_INCOMPATIBLE / «لم يُثبَّت التطبيق»).
            // الآن: مفتاح إصدار ثابت من android/key.properties، وإن غاب
            // نُفشل البناء صراحةً بدل إصدار نسخة لا تُثبَّت.
            if (!keystorePropertiesFile.exists()) {
                throw org.gradle.api.GradleException(
                    "توقيع release مفقود: أضف android/key.properties " +
                        "(أو أسرار ADMIN_KEYSTORE_* في CI). التوقيع بمفتاح debug " +
                        "يمنع تثبيت التحديث فوق النسخة المثبّتة.")
            }
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}
