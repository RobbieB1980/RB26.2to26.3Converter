# Guarded API rules for NeoForge 26.3.0.22-beta

`Repair-Known263Apis.ps1` runs JavaParser AST edits against `src/main/java` only.
It requires Java 25 and the bundled, checksum-verified JavaParser 3.28.2 runtime.
The conversion pipeline invokes Java rules only for the exact target 26.3.0.22-beta.
Unknown structures remain for review; a successful transformation is not a runtime test.

- Generated `RenderUtils` sky helpers: move six graphics imports into RenderPearl; rotate quaternion poses; bind compiled pipelines and texture uniforms. Drop old extra transform parameters only when they are the zero offset and identity matrix. Preserve geometry, shader choices, texture coordinates and draw arguments.
- Generated `NetworkMessage` record: keep payload ID, codec and handlers under one generic type; use `StreamCodec<? super RegistryFriendlyByteBuf,T>`; retain bidirectional handlers and map replacement semantics.
- Door subclasses using imported Minecraft `PushReaction`: replace `pushReaction(PushReaction.DESTROY)` with `POPPED`. The exact target `PistonStructureResolver` puts POPPED blocks into `toDestroy`.
- Root NeoForge mod `pack.mcmeta`: omit optional format declarations to avoid conflicting client/data formats, preserving description and unknown metadata. This does not alter nested standalone packs.
- Advancement `recipe_unlocked` conditions: rename a string `recipe` field to `recipes` only when the latter is absent. Preserve requirements, rewards and other conditions.

Evidence: Robmod build passed on 26.3.0.22-beta after 20 Java-file repairs. The equivalent PChaosKit rendering/networking repair passed its build and the user reported successful gameplay on 26.3.0.22-beta. Robmod runtime validation is pending. Exact local target bytecode and logs are retained in its repair evidence and shared solved case.

JavaParser core 3.28.2 is bundled under the Apache 2.0 license (lib/ast/LICENSE.APACHE).
Artifact: https://repo.maven.apache.org/maven2/com/github/javaparser/javaparser-core/3.28.2/javaparser-core-3.28.2.jar
SHA256: B5499A3B1C40B16C0671FABE478C9AAFEAB38160C6FDE74A6C13F42D86716ECD
