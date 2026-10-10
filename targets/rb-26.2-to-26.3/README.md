# RB 26.2 → 26.3 Converter 1.1.6

This is a separate target package for converting an existing NeoForge 26.2
project toward Minecraft/NeoForge 26.3. It includes deterministic migration,
dependency resolution, and a Codex repair handoff for changes that need source
analysis. The established legacy converter remains the Forge/NeoForge →
NeoForge 26.2 product.

The converter performs evidence-backed deterministic changes, then preserves
the workspace for Codex repair when additional source changes are needed:

- validates an exact NeoForge 26.2 source;
- copies to a new output directory;
- updates exact Minecraft version markers when present;
- updates `pack.mcmeta` using the 26.3 data/resource pack versions;
- migrates the safe `surface_rule` → `material_rule` worldgen rename;
- moves the documented noise-router aquifer fields when the source shape is unambiguous;
- writes a conversion manifest and migration evidence report;
- routes renderer/client API, ambiguous worldgen, and unresolved dependency work
  through the included repair workflow. Repair opens Codex with GPT-6-Luna and
  medium reasoning, the exact 26.3 primer, local solved cases, and dependency
  evidence.

The target defaults to `neoforge-26.3.0.22-beta`. Supply `-NeoVersion` when a
different official 26.3 artifact is required.

```powershell
& .\targets\rb-26.2-to-26.3\Convert-RB262To263.ps1 `
  -InputPath C:\mods\my-mod-26.2 `
  -OutputPath C:\mods\my-mod-26.3 `
  -NeoVersion 'neoforge-26.3.0.22-beta'
```

Build success, client launch, registry/data loading, and gameplay behavior are
separate validation gates. A successful deterministic conversion or build alone
does not establish runtime or gameplay correctness; use the repair workflow and
test the resulting mod in the target game profile.
