# Client and rendering changes

26.3 moves the client windowing/input/platform backend from GLFW to SDL3 and
changes renderer GPU-data storage, model submission, post effects, and render
pipelines. These are Java/API and shader-sensitive changes. The converter must
detect and report them, then use exact 26.3 sources and AST/Codex repair rather
than applying broad text substitutions.
