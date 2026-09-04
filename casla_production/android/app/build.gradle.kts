import java.io.FileInputStream
import java.util.Base64
import java.util.Properties
import org.gradle.api.GradleException

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val dartDefines = providers.gradleProperty("dart-defines").orNull
    ?.split(",")
    ?.mapNotNull { encoded ->
        runCatching {
            String(Base64.getDecoder().decode(encoded))
                .split("=", limit = 2)
                .takeIf { it.size == 2 }
        }.getOrNull()
    }
    ?.associate { it[0] to it[1] }
    ?: emptyMap()

val localSigningProperties = Properties()
val localSigningFile = rootProject.file("key.properties")
if (localSigningFile.isFile) {
    FileInputStream(localSigningFile).use(localSigningProperties::load)
}

fun configuredValue(
    environmentName: String,
    gradlePropertyName: String,
    localPropertyName: String? = null,
): String? = providers.gradleProperty(gradlePropertyName).orNull
    ?: System.getenv(environmentName)
    ?: localPropertyName?.let(localSigningProperties::getProperty)

val placeholderApplicationId = "com.example.casla_production"
val productionApplicationId = configuredValue(
    environmentName = "CASLA_ANDROID_APPLICATION_ID",
    gradlePropertyName = "CASLA_ANDROID_APPLICATION_ID",
) ?: placeholderApplicationId

val productionStoreFile = configuredValue(
    environmentName = "CASLA_ANDROID_STORE_FILE",
    gradlePropertyName = "CASLA_ANDROID_STORE_FILE",
    localPropertyName = "storeFile",
)
val productionStorePassword = configuredValue(
    environmentName = "CASLA_ANDROID_STORE_PASSWORD",
    gradlePropertyName = "CASLA_ANDROID_STORE_PASSWORD",
    localPropertyName = "storePassword",
)
val productionKeyAlias = configuredValue(
    environmentName = "CASLA_ANDROID_KEY_ALIAS",
    gradlePropertyName = "CASLA_ANDROID_KEY_ALIAS",
    localPropertyName = "keyAlias",
)
val productionKeyPassword = configuredValue(
    environmentName = "CASLA_ANDROID_KEY_PASSWORD",
    gradlePropertyName = "CASLA_ANDROID_KEY_PASSWORD",
    localPropertyName = "keyPassword",
)

val productionSigningReady = listOf(
    productionStoreFile,
    productionStorePassword,
    productionKeyAlias,
    productionKeyPassword,
).all { !it.isNullOrBlank() }

android {
    namespace = "com.example.casla_production"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        resValues = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = productionApplicationId
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    flavorDimensions += "environment"
    productFlavors {
        create("dev") {
            dimension = "environment"
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            resValue("string", "app_name", dartDefines["APP_NAME"] ?: "Casla Dev")
        }
        create("staging") {
            dimension = "environment"
            applicationIdSuffix = ".staging"
            versionNameSuffix = "-staging"
            resValue(
                "string",
                "app_name",
                dartDefines["APP_NAME"] ?: "Casla Staging",
            )
        }
        create("production") {
            dimension = "environment"
            resValue(
                "string",
                "app_name",
                dartDefines["APP_NAME"] ?: "Casla Group",
            )
        }
    }

    signingConfigs {
        create("production") {
            if (productionSigningReady) {
                storeFile = rootProject.file(productionStoreFile!!)
                storePassword = productionStorePassword
                keyAlias = productionKeyAlias
                keyPassword = productionKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // Never fall back to debug signing. The verification task below
            // blocks productionRelease unless the real identity and all signing
            // inputs are explicitly supplied.
            if (productionSigningReady) {
                signingConfig = signingConfigs.getByName("production")
            }
        }
    }
}

val verifyCaslaSigning by tasks.registering {
    group = "verification"
    description = "Fail closed unless the production Android identity and signing inputs are configured."

    doLast {
        val problems = mutableListOf<String>()
        if (productionApplicationId == placeholderApplicationId) {
            problems += "CASLA_ANDROID_APPLICATION_ID still uses the placeholder value"
        }
        if (productionStoreFile.isNullOrBlank()) {
            problems += "CASLA_ANDROID_STORE_FILE/storeFile is missing"
        } else if (!rootProject.file(productionStoreFile).isFile) {
            problems += "configured production keystore file does not exist"
        }
        if (productionStorePassword.isNullOrBlank()) {
            problems += "CASLA_ANDROID_STORE_PASSWORD/storePassword is missing"
        }
        if (productionKeyAlias.isNullOrBlank()) {
            problems += "CASLA_ANDROID_KEY_ALIAS/keyAlias is missing"
        }
        if (productionKeyPassword.isNullOrBlank()) {
            problems += "CASLA_ANDROID_KEY_PASSWORD/keyPassword is missing"
        }

        if (problems.isNotEmpty()) {
            throw GradleException(
                "Production Android release is not configured:\n - " +
                    problems.joinToString("\n - "),
            )
        }
    }
}

// Any production release entry point must validate identity/signing first.
// Debug production builds stay available to CI so the flavor can be compiled
// without exposing release credentials.
tasks.configureEach {
    if (name.contains("ProductionRelease", ignoreCase = true)) {
        dependsOn(verifyCaslaSigning)
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
