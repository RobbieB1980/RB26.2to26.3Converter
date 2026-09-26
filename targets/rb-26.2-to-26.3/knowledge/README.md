# 26.2 → 26.3 knowledge bundle

`PrimerChangeIndex-26.2-to-26.3.json` is the machine-readable routing index.
It deliberately distinguishes deterministic changes from changes that require
exact NeoForge source, AST repair, or runtime validation.

The index is derived from the official Minecraft 26.2/26.3 release notes and
the NeoForged migration primer. It is a routing/evidence layer, not a claim
that every API or mod behavior can be inferred from a release-note summary.

The full upstream primer is retained in `Official-Primer-26.2-to-26.3.md` with
revision, checksum and CC-BY-4.0 attribution in `official-primer-source.json`.
`build-toolchain.md` contains separately labeled local build evidence.
Repair prefers the copies under `C:\GokuCodexAI\Data\NeoForge_Primers\26.3`
and falls back to this packaged knowledge when they are unavailable.

Both converter and repair builds use `Build-WithDestinationJava.ps1`, which
retains successful build evidence under the project's `.gokuai/solved-cases`
and `C:\GokuCodexAI\Data\Solved_Problems\rb-26.2-to-26.3\build-history`.
These snapshots preserve configuration, reports, logs and hashes. Failed builds
are not promoted. Runtime remains untested until independently validated.
Diagnosed reusable fixes stay in the dedicated solutions index with exact
source/target/pin and failure-pattern matching; build history is not an automatic
patch rule. Repair must record its diagnosis and validation in `result.json`.
