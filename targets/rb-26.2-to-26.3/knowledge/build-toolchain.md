# Local converter toolchain evidence (26.2 to 26.3)

This is local implementation evidence, separate from the official vanilla API
primer. Read the failed project's actual Gradle files before applying any fix.

- Destination Java: 25. Build-WithDestinationJava.ps1 resolves the destination
  JDK and pins org.gradle.java.home before invoking the project wrapper.
- Scaffold plugin: net.neoforged.moddev 2.0.144, as declared by the bundled
  legacy-pipeline/Convert-Forge1201-ToNeoForge262.ps1 scaffold implementation.
  That internal filename is historical; do not run its older migration rules
  directly as the 26.3 repair strategy.
- Verified BuildPaste wrapper: Gradle 9.2.1. Wrapper acquisition may use a local
  reference, so always read gradle/wrapper/gradle-wrapper.properties; this is
  observed build evidence, not a universal wrapper pin.
- Target default: NeoForge 26.3.0.7-beta. Match the conversion manifest pin.
- The target converter writes neoForge.enable with version = project.neo_version
  and disableRecompilation = true. Preserve this tested configuration; consult
  exact plugin sources before changing DSL or re-enabling recompilation.
- GUI GeckoLib default: geckolib-neoforge-26.3-5.5.7. Only resolve it when the mod
  needs GeckoLib. Older project properties can survive; inspect resolved
  dependencies rather than assuming a GUI default was applied to every project.
- Preserve project-specific repositories, dependency versions and modId.
- Java source writers must use UTF-8 without BOM, including after API rewrites.
- Build helper merges native stderr inside cmd so PowerShell 5.1 reports the
  actual Gradle exit code and captures complete output in compile-errors.log.
- A successful BuildPaste Java 25 build verified the above build path. It does
  not prove client/server loading, registry completeness or gameplay correctness.

Repair evidence must include build.gradle(.kts), settings.gradle(.kts),
gradle.properties, the wrapper properties, version catalog when present,
conversion manifest, compile report and log. Use exact resolved artifacts under
build/moddev/artifacts for target API evidence; the vanilla primer alone does
not establish ModDevGradle DSL or NeoForge APIs.
