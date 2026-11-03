// Drift for Android. Built by GitHub Actions (.github/workflows/android.yml).
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // NewPipeExtractor (YouTube) is published through JitPack.
        maven(url = "https://jitpack.io")
    }
}

rootProject.name = "Drift"
include(":app")
