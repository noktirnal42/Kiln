# Licensing: options, recommendation and the steps to apply it

Research and draft for an owner decision, 2026-11-09. This is not legal advice; have a lawyer review the final
terms. The draft is on branch `license-draft` (nothing public has changed until it is merged and pushed).

## Goal

Make the terms more restrictive so that the people who build and distribute Kiln can earn money from it, while
keeping the source visible. Today the repository is MIT, which lets anyone, including companies, use, sell and
redistribute Kiln with no payment.

## Facts that shape the choice

- **Ownership looks simple.** The git history has 224 commits from one owner under two names (Codex's commits
  use the same identity) and no outside contributors, so the owner can relicense the code they wrote. Confirm no
  one else's code (pasted snippets, an employer's rights) is in the tree.
- **The past stays MIT.** Anyone who already has `v0.1.0` or `v0.1.1`, or a clone of the repository, keeps the
  MIT rights for those copies. A license change applies to new versions only. The draft keeps the MIT text in
  `licenses/` and explains this in `LICENSE-HISTORY.md`. Do not claim the earlier grants are revoked.
- **Dependencies allow it.** Everything linked is MIT or Apache-2.0 (MLX, SwiftTerm, EventSource, yyjson,
  Apple's and Hugging Face's Swift packages, and others). They permit redistribution under other terms provided
  their copyright and license notices are kept: `THIRD-PARTY-NOTICES.md` reproduces them in full, and the app should
  show them in an About / Acknowledgements screen. Ghidra (Apache-2.0), radare2 (LGPL-3.0), lldb, adb and the Android
  emulator are separate programs the user installs and Kiln only runs; do not bundle them without checking their terms.
- **"Open source" has a definition.** Licenses that restrict commercial use are *source-available*, not open source
  as the [Open Source Initiative defines it](https://opensource.org/osd). Public wording must change (the draft does it).
- **A license does not stop piracy.** It gives you the legal right to say no and to sell permission. Revenue also
  needs a way to sell and deliver (notarized builds with a license key or the App Store), a trademark, and support terms.

## Options

| Option | Who can use Kiln free | Who must pay | Revenue fit | Costs and risks |
| --- | --- | --- | --- | --- |
| **A. PolyForm Noncommercial 1.0.0 + paid commercial license (recommended)** | Individuals, hobbyists, researchers, schools, charities and public bodies, for noncommercial purposes; may modify and share noncommercially | Any business or anyone using it for paid work | Strong: companies, consultants and freelancers need an agreement; you set the price | Not open source; deters some contributors (the CLA covers that); "noncommercial" has gray areas that the license text defines |
| B. PolyForm Strict 1.0.0 | Noncommercial use only, no modifying or redistributing | Everyone else | Strongest control over the code | Contributors cannot share changes at all; weak community |
| C. [FSL-1.1](https://spdx.org/licenses/FSL-1.1-MIT.html) (Functional Source License) | Anyone, for any purpose except a competing product or service | Only rivals, who must negotiate | Weak: ordinary businesses use it free; it blocks clones, not non-paying users | Each release converts to MIT or Apache-2.0 after two years |
| D. BSL 1.1 (Business Source License) | Whatever your "additional use grant" allows (for example non-production) | Production or commercial use you choose to gate | Strong if the grant is narrow | You must set the use grant, change date (up to four years) and change license; converts to an open license |
| E. [PolyForm Shield](https://polyformproject.org/licenses/) | Anyone, except those competing with the licensor | Only competitors | Weak, as C | Not open source |
| F. All rights reserved (proprietary EULA, closed or view-only repository) | Only as the EULA allows | Everyone, by agreement | Maximum | No public license to read, run or modify; loses transparency, the audit and trust story, and contributions; existing public history stays MIT |

Sources: [PolyForm license suite](https://polyformproject.org/licenses/), [FSL announcement](https://blog.sentry.io/introducing-the-functional-source-license-freedom-without-free-riding),
[SPDX FSL-1.1-MIT](https://spdx.org/licenses/FSL-1.1-MIT.html), [relicensing notes](https://writing.kemitchell.com/2023/09/23/Two-Kinds-Relicensing).
Option D is only as restrictive as the additional use grant you write; D and F need custom text and a lawyer.

## Recommendation

**Option A.** It is the most restrictive choice that keeps the source public and the community able to read, run
and improve Kiln for free, and it makes every business user a potential customer. Pair it with:

1. A **commercial license** (`COMMERCIAL-LICENSE.md`): per-seat or per-team pricing, what support is included.
2. A **contributor agreement** (`CLA.md`) so future contributions can also be licensed commercially.
3. A **trademark policy** (`TRADEMARKS.md`): keeps forks and resellers from using the Kiln name and logo.
4. **Distribution**: keep the notarized direct download and decide on App Store, subscriptions or license keys; add
   in-app license activation and an About screen with the notices when you are ready (separate engineering task).
5. Keep **sponsorship** optional and separate. Do not put payment links of any other entity on the site.

Choose B or D instead if you want to forbid forks entirely (B) or gate production use differently (D); choose F only
if you are willing to give up public source.

## Checklist to apply Option A (the draft already contains the files marked ✔)

- ✔ `LICENSE` = PolyForm Noncommercial 1.0.0 (official text) with a Required Notice line.
  The Required Notice names FreeRange Labs; confirm that is the correct legal name or entity before release.
- ✔ `LICENSE-HISTORY.md` and `licenses/MIT-through-v0.1.1.txt`: keep the MIT record.
- ✔ `COMMERCIAL-LICENSE.md` (placeholders for price, support terms and contact), `CLA.md`, `TRADEMARKS.md`.
- ✔ `THIRD-PARTY-NOTICES.md` generated from the real dependency licenses.
- ✔ `Scripts/relicense-references.sh` rewrites the public "MIT" and "open source" wording in README, CONTRIBUTING and the site.
  Rerun it after any docs change before merging.
- ☐ Lawyer review of `LICENSE` choice, the commercial agreement, the CLA and the trademark policy.
- ☐ Trademark search for "Kiln" in software classes and countries; decide on registration.
- ☐ Business side: who receives the money (a legal entity), taxes, payment processing, refund and EULA terms. These are the
  owner's to set up; none is done by the repository.
- ☐ Release the first PolyForm version as `v0.2.0`; mention the change in the release notes and on the site.
- ☐ In-app About / Acknowledgements screen showing the notices; project metadata (`NSHumanReadableCopyright`).
- ☐ Set the GitHub repository license metadata (it reads `LICENSE`; PolyForm shows as "Other").
