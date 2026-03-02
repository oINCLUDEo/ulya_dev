allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

subprojects {
    afterEvaluate {
        // Принудительно buildToolsVersion 34 для всех
        extensions.findByType<com.android.build.gradle.BaseExtension>()
            ?.buildToolsVersion = "35.0.1"

        // Патч: после генерации AIDL файлов — убираем проблемный комментарий
        tasks.matching { it.name.startsWith("compile") && it.name.endsWith("JavaWithJavac") }
            .configureEach {
                doFirst {
                    val aidlOutDir = file("${project.layout.buildDirectory.get()}/generated/aidl_source_output_dir")
                    if (aidlOutDir.exists()) {
                        aidlOutDir.walkTopDown()
                            .filter { it.extension == "java" }
                            .forEach { javaFile ->
                                val original = javaFile.readText()
                                // Удаляем строку с "Using:" которая содержит пути с backslash
                                val patched = original.lines().joinToString("\n") { line ->
                                    if (line.trimStart().startsWith("* Using:")) {
                                        " * Using: [path removed for Windows compatibility]"
                                    } else {
                                        line
                                    }
                                }
                                if (original != patched) {
                                    javaFile.writeText(patched)
                                    println("Patched AIDL file: ${javaFile.name}")
                                }
                            }
                    }
                }
            }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}