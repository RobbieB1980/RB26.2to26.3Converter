# 1.1.6

- Final Windows release: package the standalone GUI, portable tools, target-specific repair knowledge, and installer. Codex repair uses GPT-6-Luna with medium reasoning.

- Add exact NeoForge 26.3 AST repairs for TOWW/MCreator worldgen features, feature registration, command source construction, dynamic StateHolder property writes, and structure template accessors.
- Keep 26.2 -> 26.3 TOWW evidence in the target-specific solved-case catalog; prevent it from injecting pre-26.2 migration passes.
- Reject JAR inputs without exact Minecraft 26.2 NeoForge metadata before running conversion stages.
- Resolve dependencies with an installed Python 3.11+ runtime when the Windows Python launcher is unavailable.
- Add fixture coverage for the new API families, idempotence, target guards, and unrelated source preservation.

# 1.1.5

- Harden dependency catalog resolution for entries without a `Kind` property, including GeckoLib's official Maven entry.
- Harden client item-model conversion for composite `condition`/`range_dispatch` documents.
- Repackage the desktop installer and portable payload with both fixes.

# 1.1.4

- Promote six exact-version solved-case records from PChaosKit and Robmod into bundled and shared repair knowledge.
- Retain source fingerprints, applied-rule reports, and repair results after successful builds.
- Repair sessions retrieve up to five same-project, exact-target build histories and current applied-rule evidence.
- Keep user-reported runtime confirmation distinct from compilation and automatic rule eligibility.

# 1.1.3

- Apply guarded JavaParser rules for known generated sky rendering, payload registration, and door piston reactions on exact NeoForge 26.3.0.22-beta.
- Migrate recipe-unlocked advancement conditions while preserving rewards and requirements.
- Remove conflicting optional format declarations from root NeoForge mod pack metadata.
- Bundle pinned JavaParser 3.28.2 for offline repair; preserve unfamiliar source variants for review.
- Robmod full build verified; runtime test remains pending.

# 1.1.2

- Default target updated to NeoForge 26.3.0.22-beta in the GUI, conversion entry points, target manifest and toolchain knowledge.
- Historical solved-case version pins retained as evidence.

# Preview changelog

## 1.1.1

- Bundle and verify Vineflower 1.12.0 explicitly in both portable and installer
  payloads. JAR decompilation no longer requires a first-run download.
- Verify cached/downloaded Vineflower against its published SHA-256; use both
  official Maven Central endpoints if the packaged tool is missing or damaged.

## 1.1.0

- Added verified dependency cache/index, separate 26.2 source references and
  26.3 target artifacts, offline reuse, required dependency build gates, and
  Python 3.14 metadata parsing. Wired the GUI GeckoLib selection into resolution.
- Added resource preservation hashes and original input snapshots, recognizing
  generated metadata. Preserve original non-platform dependency declarations.
- Added rendering/tool/networking API review triggers, exact source repair
  evidence, and Mojang/Misode supplementary reference registration.
- Converter and repair build cases now retain dependency and preservation reports.

## 0.1.0-preview

- Added an isolated NeoForge 26.2 → 26.3 target contract.
- Added strict source/output validation and deterministic migration evidence.
- Added a separate Windows GUI and self-contained preview packaging path.
- Kept the legacy → 26.2 converter and release path unchanged.
