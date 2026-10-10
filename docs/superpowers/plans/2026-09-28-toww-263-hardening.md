# TOWW 26.3 Conversion Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the converter repair the TOWW 26.2 source/API families that currently prevent NeoForge 26.3 compilation, then record the case only after a clean build.

**Architecture:** Extend the exact-target Java AST repair layer with narrowly scoped transformations for MCreator worldgen features, `CommandSourceStack`, and `StateHolder.setValue` call sites. Add fixture-based regression tests and a separate TOWW 26.2 solved-case entry; do not broaden generic regex rewriting or invent dependency changes.

**Tech Stack:** PowerShell, JavaParser AST worker, Gradle/NeoForge 26.3.0.22-beta, JSON solved-case index.

**Spec:** Approved TOWW compile-error diagnosis in the current conversation.

## Global Constraints

- Target repairs apply only to exact NeoForge `26.3.0.22-beta`.
- The original input JAR remains unchanged.
- Build success and runtime success remain separate gates.
- No dependency version is changed unless the build evidence requires it.
- No agents are used.

## Review Focus

- MCreator `Feature` generic removal: registration and six feature classes compile against 26.3.
- `CommandSourceStack` constructor changes: converted command sources preserve permission/entity/position context.
- `StateHolder.setValue`: property/value calls retain typed property semantics.
- Idempotence: running the AST repair twice produces the same source.
- Target and unrelated-file guards: repairs do not run for other targets or unrelated Java.

---

### Task 1: Add failing TOWW API-family fixtures

**Files:**
- Modify: `scripts/Test-Known263Apis.ps1`
- Create/modify: fixture sources under the existing known-API fixture directory.

**Interfaces:**
- Consumes the existing JavaParser worker and exact-target test harness.
- Produces red tests for the three TOWW API families plus idempotence and guards.

- [ ] Add minimal fixture snippets representing feature registration/classes, command source construction, and state-holder mutation.
- [ ] Run the focused test and confirm it fails because the current worker leaves the 26.2 forms unchanged.

### Task 2: Implement exact 26.3 AST repairs

**Files:**
- Modify: `targets/rb-26.2-to-26.3/legacy-pipeline/lib/ast/Known263Apis.java`
- Modify: `targets/rb-26.2-to-26.3/legacy-pipeline/lib/Repair-Known263Apis.ps1` only if fixture plumbing requires it.

**Interfaces:**
- Preserve the existing worker entry point and exact target guard.
- Emit deterministic source with no broad textual replacement.

- [ ] Implement the smallest AST transformations required by the red fixtures.
- [ ] Run the focused tests and confirm all three families pass.
- [ ] Run idempotence, exact-target, unrelated-file, and existing known-API tests.

### Task 3: Add the build-gated TOWW solved case

**Files:**
- Modify: `targets/rb-26.2-to-26.3/legacy-pipeline/lib/SolvedConversionIndex.json`
- Modify: associated solved-case documentation/tests if the index schema requires it.

**Interfaces:**
- New case is distinct from the existing 1.20.1 TOWW case.
- Match requires mod id `the_one_who_watches`, source `26.2`, and target `26.3.0.22-beta`.
- Case is marked build-verified only after the converted project compiles cleanly.

- [ ] Add the 26.2→26.3 case referencing only the validated AST/API passes.
- [ ] Validate index parsing and matching behavior.

### Task 4: Convert, compile, and package evidence

**Files:**
- Modify: converter source only as needed from Tasks 1–3.
- Generated output: TOWW conversion directory and compile log.

- [ ] Re-run the TOWW conversion from the original JAR.
- [ ] Run the generated Gradle build with the project’s configured Java/toolchain.
- [ ] If compilation fails, classify the next error family and continue only with evidence-backed repairs.
- [ ] On clean compile, update the solved case to build-verified and rebuild the release package.
- [ ] Verify the package contains the hardened source and report build/runtime gates separately.
