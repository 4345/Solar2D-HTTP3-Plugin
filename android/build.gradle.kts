buildscript {
    repositories {
        google()
        jcenter()
        mavenCentral()
    }
    dependencies {
        // kotlin-gradle-plugin убран вместе с самим Kotlin: единственный
        // Kotlin-класс плагина был переписан на Java, см. plugin/build.gradle.
        classpath("com.android.tools.build:gradle:8.13.2")
        classpath("com.beust:klaxon:5.5")
    }
}

allprojects {
    repositories {
        google()
        jcenter()
        mavenCentral()
        // maven(url = "https:// some custom repo")
        val nativeDir = if (System.getProperty("os.name").lowercase().contains("windows")) {
            System.getenv("CORONA_ROOT")
        } else {
            "${System.getenv("HOME")}/Library/Application Support/Corona/Native/"
        }
        flatDir {
            dirs("$nativeDir/Corona/android/lib/gradle", "$nativeDir/Corona/android/lib/Corona/libs")
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory.asFile.get())
}
