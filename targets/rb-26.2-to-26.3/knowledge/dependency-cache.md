# 26.2 to 26.3 dependency cache and preservation

The converter uses Python 3.14 (the Windows `py -3.14` launcher) with only the
standard library. Missing Python is reported as a dependency-resolution failure;
the partially converted output is retained for repair.

Shared root: `C:\GokuCodexAI\Data\Mod_Dependencies`.

- `dependency-index.json`: trusted mod-to-project identity mappings and acquired
  target artifacts, URLs, version IDs, declared ranges and hashes. Existing local
  mappings are preserved. New unknown mod IDs require an explicit verified mapping.
- `minecraft-26.2`: reference artifacts for source investigation, never selected
  as destination build dependencies. References are not necessarily the exact
  dependency version originally used by the mod.
- `minecraft-26.3`: target artifacts and release metadata. Automatic acquisition
  currently uses Modrinth's published API, exact game/loader filtering, a fixed
  GeckoLib default of 5.5.7, JAR mod identity and upstream SHA-512 checksums.
- Ordinary Maven dependencies remain in their existing Gradle repositories and
  Gradle cache. This resolver does not guess coordinates, parse arbitrary Gradle
  programs or auto-port unavailable libraries. Catalog-matched literal mod
  dependencies can be replaced by verified local target JARs. Dynamic Gradle
  expressions, embedded libraries and optional mods are explicitly reported.

Usage (from the packaged tools/rb-26.2-to-26.3 directory):

```powershell
.\Resolve-Dependencies.ps1 -SourcePath 'D:\original.jar' -ProjectRoot 'D:\converted'
.\Resolve-Dependencies.ps1 -SourcePath 'D:\original.jar' -ProjectRoot 'D:\converted' -Offline
```

The source can also be a project folder. `-CacheRoot` allows an isolated cache
for testing. Target JARs are copied into output `libs/rb-26.3`; unrelated installs
and original inputs are never deleted. Downloads are checked before atomic
promotion. Cached files are rehashed before reuse. Index updates are atomic and
serialized using an OS lock. Failed downloads leave a visible blocker.

Output evidence:

- `dependency-detection.json`: original declarations and literal Gradle evidence.
- `dependency-resolution.json` / `DEPENDENCIES-26.3.md`: outcomes and required
  blockers. Exit 3 means required dependency repair is needed; build is gated.
- `rb-dependencies.gradle`: isolated generated dependency declarations. Existing
  Gradle customizations remain; only identified literal coordinates are changed.
- `RESOURCE_PRESERVATION.json`: original/output resource hashes, modified files,
  restored missing resources, and archive signatures excluded from the new JAR.
  Generated NeoForge metadata is recognized to avoid duplicate resources.
- `.gokuai/source-evidence`: original JAR or project resource snapshots.
- `API_REVIEW-26.3.json`: file/line review triggers for rendering, PoseStack,
  removed tool classes and networking codecs. These never rewrite Java themselves.

Original non-platform mod dependency declarations are preserved through JAR
scaffolding. Required transitive dependencies are resolved or reported blocked.
Original dependency version ranges are respected; incompatible ranges require
explicit migration review. Embedded libraries remain embedded and require review.
Successful build cases capture dependency reports, pins/hashes and resource audit.
Runtime remains untested until independently checked. Runtime fixes must be
hardened with failure evidence, exact target versions and regression validation.

Sources: [Modrinth versions API](https://docs.modrinth.com/api/operations/getprojectversions/),
[NeoForge mod metadata](https://docs.neoforged.net/docs/gettingstarted/modfiles/).
Additional vanilla references are registered in `supplementary-sources.json`.
