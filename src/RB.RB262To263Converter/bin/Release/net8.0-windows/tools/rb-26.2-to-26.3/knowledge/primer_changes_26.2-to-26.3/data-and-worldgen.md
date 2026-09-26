# Data and worldgen changes

26.3 splits context integer and float number providers, revises registry
references in loot/predicate data, renames block-state fields, and changes noise
settings. `surface_rule` becomes `material_rule`; aquifer inputs move into an
`aquifers` object; ore-vein controls become a material rule; and carver formats
are revised. Only unambiguous shape-preserving moves are deterministic.
