# Security policy

Kiln can operate on local files, execute commands, call providers, inspect binaries, and expose an authenticated local MCP endpoint. Security-sensitive changes need careful review.

## Report a vulnerability privately

Use GitHub's [private vulnerability reporting page](https://github.com/noktirnal42/Kiln/security/advisories/new) when it is available. Include the affected commit, a minimal reproduction, impact, and a proposed mitigation if you have one. Use synthetic data and redact credentials.

If GitHub does not offer private reporting for this repository, do not open a public issue containing exploit details, keys, private data, or weaponized attachments. You may open an issue that only asks for a private reporting channel. No private email address is currently published here.

There is no guaranteed response or remediation timeline. Coordinated disclosure is appreciated; allow maintainers an opportunity to reproduce and address a report before public disclosure.

## Support status

The development branch is the only currently maintained code line. A successful build or a development test run is not a security certification. No long-term support or backport policy has been established.

## Boundaries contributors must preserve

- Keep provider credentials in the Keychain and out of source, logs, fixtures, issue bodies, screenshots, and generated artifacts.
- Keep policy checks and human approval gates for agent writes, execution, and network access. UI actions and MCP calls should use the same underlying services and applicable checks.
- Keep the MCP server loopback-only and authenticated by default. Never publish its bearer token.
- Treat imported binaries, model output, tool output, repository text, and model/dataset metadata as untrusted inputs.
- Preserve workspace path checks, output bounds, cancellation, and audit records.
- Do not equate heuristic secret redaction, an approval gate, or a local model with complete containment or privacy guarantees.

Provider requests may transmit prompts, selected context, and tool results to the selected service. Third-party providers, model weights, datasets, and external tools have their own terms and security properties.
