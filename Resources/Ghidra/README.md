# Kiln's Ghidra exporter

`AxiomExport.java` is the original exporter from this project's Axiom RE codebase,
`Engine/Ghidra/AxiomExport.java` at revision `a1c3262107d0b7a73c30a27673bd197026a0b4be`.
The source attribution is preserved. It references upstream Ghidra APIs and runs
inside the user's separately installed Ghidra. No Ghidra distribution, libraries
or decompiler executable are bundled with Kiln.

It exports functions, assembly, decompiled pseudocode, basic blocks and references
as bounded JSON for the existing AxiomCore loader. Analysis does not execute the
target binary.
