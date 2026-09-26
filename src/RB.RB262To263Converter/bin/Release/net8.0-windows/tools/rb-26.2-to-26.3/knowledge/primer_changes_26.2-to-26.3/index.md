# Primer changes: 26.2 → 26.3

The ordered migration families are:

1. Target and pack metadata
2. Data codecs and registry references
3. Worldgen noise settings, material rules, and carvers
4. Items, maps, recipes, and components
5. Client windowing, rendering, shaders, and resource reload
6. Server management and build/dependency validation

Deterministic JSON changes are allowed only where the index marks the risk as
`deterministic` or `mixed` with an unambiguous source shape. Java rendering and
SDL3 changes always require exact target sources and a separate compile/client
validation gate.
