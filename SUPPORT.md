# Support and help

Kiln is in active development. Community support is provided through GitHub on a best-effort basis; there is no guaranteed response time or commercial support agreement.

- **Setup or usage:** start with the [README](README.md), [documentation index](docs/README.md), and [known issues](docs/KNOWN-ISSUES.md).
- **A reproducible defect:** [open a bug report](https://github.com/noktirnal42/Kiln/issues/new?template=bug_report.yml).
- **A feature or workflow improvement:** [open a feature request](https://github.com/noktirnal42/Kiln/issues/new?template=feature_request.yml).
- **Want to help:** read [contribution areas](docs/CONTRIBUTION-AREAS.md) and [CONTRIBUTING](CONTRIBUTING.md).
- **A security concern:** follow [SECURITY](SECURITY.md). Do not disclose exploitable details or credentials in a public issue.

## Before reporting

Record the commit/build, macOS and Xcode versions, hardware and memory, and the relevant workflow. For provider problems, name the provider and model, whether the catalog loaded, and the observed error/status. Include a minimal synthetic example where possible.

Remove API keys, bearer tokens, private prompts, personal file paths, private source code, and sensitive binary contents from reports. Do not upload your Keychain, application data directory, entire logs, or a private model/dataset just to reproduce a problem.

## Common problems

**The app cannot find a model.** Check Settings, the provider's account/credits, and whether the local server is running. A catalog entry does not guarantee that your account can use that model. Different models from the same provider may have different access requirements.

**A small model prints JSON or does not finish an agent task.** Plain chat and reliable tool use are different capabilities. The local 3B model used during QA has failed real tool and swarm tasks. Try a stronger tool-capable model, keep the task small, and attach a redacted reproduction.

**MLX is available but a run fails.** Availability can mean that the runtime is linked; the model, download, memory budget, Metal runtime, and actual execution must also work. Report the exact operation and error. Successful CLI training does not certify every GUI lifecycle path.

**Ghidra or an export option is unavailable.** Some operations require separately installed and configured tools. See the failure message and [known issues](docs/KNOWN-ISSUES.md); no bundled Ghidra or GGUF conversion capability should be assumed.

**The app still shows an old icon or behavior.** Confirm which `.app` bundle is running. A successful source build does not replace every older copy on your Mac. Quit the older instance and open the bundle you just built.

## Supporting development

Useful bug reports, testing, documentation, and code contributions all help. Donation options will be linked from the repository and project site when a verified destination is available. Do not send money to an address posted by an unverified third party in an issue or comment. Donations do not purchase features, priority, or a delivery commitment.
