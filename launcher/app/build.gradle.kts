plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "tv.h96.movielauncher"
    compileSdk = 35

    defaultConfig {
        applicationId = "tv.h96.movielauncher"
        // 26 — минимум, при котором ещё жив ADAPTIVE_ICON и современный
        // PackageManager API. Ниже опускаться смысла нет: система у нас 15.
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1"
    }

    buildTypes {
        release {
            // Лаунчер обязан стартовать быстро (ТЗ §33). R8 уменьшает dex и
            // ускоряет загрузку классов; правил оставляем минимум, потому что
            // рефлексии здесь нет.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        debug {
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

    buildFeatures {
        // Никаких Compose и ViewBinding: ТЗ §33 требует быстрого старта и
        // отсутствия тяжёлых фреймворков. Обычные View + findViewById.
        viewBinding = false
        compose = false
    }
}

dependencies {
    // Зависимости намеренно сведены к минимуму.
    //
    // Чего здесь НЕТ и почему:
    //   androidx.leanback  — тянет много, а нужна только сетка с D-pad,
    //                        она делается на RecyclerView (ТЗ §34);
    //   Glide / Coil       — иконки берутся из PackageManager, они уже
    //                        в памяти, сеть не используется (ТЗ §33);
    //   Compose            — старт медленнее, выигрыша для сетки плиток нет.
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.recyclerview:recyclerview:1.3.2")
}
