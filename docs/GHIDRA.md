# Ghidra analysis in Kiln

Kiln uses a separately installed Ghidra to recover functions, pseudocode, basic
blocks and references. It never runs the target binary. The original imported
project remains intact if engine analysis fails.

On startup Kiln checks `GHIDRA_HOME` inherited by its process, then installation
folders named `ghidra…` in `~/Applications` and `/Applications`. A valid install
must have an executable `support/analyzeHeadless` and Ghidra 11 or newer metadata.
Among discovered versions, the highest `PUBLIC` release takes precedence over
development builds. A valid explicit `GHIDRA_HOME` takes precedence over discovery.
Restart Kiln after changing the installation.

The export script is included with Kiln; the Ghidra application and Java runtime
are not. Ghidra's own Java requirements still apply. On this Mac, Ghidra 12.1.4
and Java 21 produced pseudocode for a copy of `/usr/bin/true` during the standalone
engine verification. That establishes this installation's execution, not broad
decompilation accuracy or parity with the complete Ghidra application.

Import a binary in **Analyze**, select its project, then choose **Analyze with
Ghidra**. The header reports the discovered installation or why it is unavailable.
Functions and pseudocode appear after analysis completes. Failures show an error
and retain the native inspection. Only one Ghidra run is allowed at a time, with
the existing 240-second engine bound.

The Workstation Agent and Kiln's external MCP server expose the same service as
`re_analyze_binary`, taking an existing `project_id`. This is an execution action,
subject to Kiln's policy and approval gates. `re_get_decompilation` reads the saved
results. Reanalysis preserves the project ID, analyst annotations and revision
checks; it refuses to replace results if the imported binary changed.

The opt-in `LiveGhidraTests` fixture exercises import, the real agent tool,
duplicate-run rejection, persisted pseudocode and annotation preservation.
Enable it with `TEST_RUNNER_KILN_LIVE_GHIDRA=1` for `xcodebuild test` and select
`-only-testing:KilnTests/LiveGhidraTests`. It requires an installed engine and can
take several minutes. Normal discovery tests use inert temporary launchers and
do not run Ghidra.
