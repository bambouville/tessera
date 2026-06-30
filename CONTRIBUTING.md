# Contributing to Tessera

Thank you for your interest in Tessera!

## How development works

Tessera is developed in a private repository; this public repository receives
one squashed source snapshot per released build (tagged `vX.Y.Z`), so that
every App Store binary corresponds to published source. Issues are very
welcome here. Pull requests can be reviewed here too, but accepted changes are
applied in the development repository and appear in the next release snapshot
(with credit in the commit message), rather than being merged directly.

## Licensing of contributions (important)

Tessera is distributed under the **GNU GPL v3** (see `LICENSE`) **with an
additional permission** under GPLv3 section 7 that allows conveying the app
through the Apple App Store and TestFlight (see `COPYING.iOS`). Without that
additional permission, GPL-licensed code cannot be distributed on the App
Store at all.

Because every contributor holds the copyright on their contribution, Bambouville
Inc.'s official App Store / TestFlight distribution only keeps working if **every
contribution grants Bambouville that same distribution permission**. (The
`COPYING.iOS` App Store/TestFlight permission is granted only to Bambouville
Inc.'s official and authorized distribution — not to third parties.) Therefore:

> By submitting a contribution to Tessera, you agree that your contribution is
> licensed under GPL-3.0-or-later, and you **grant Bambouville Inc. (and persons
> acting on its behalf or with its prior written authorization) the same App
> Store / TestFlight distribution permission set out in `COPYING.iOS`** for your
> contribution, so that the official Tessera distribution may include it. You
> also certify the Developer Certificate of Origin (DCO,
> <https://developercertificate.org>) for your contribution.

Please add a `Signed-off-by: Your Name <email>` line to your commits
(`git commit -s`) to record the DCO certification. Contributions that cannot
be licensed under these terms (for example, code copied from a project with an
incompatible license) cannot be accepted.

## Practical notes

- Mosh code lives in a submodule pinned to a published fork
  (`bambouville/mosh`, branch `tessera-ios`); changes to mosh itself should
  ideally go upstream to `mobile-shell/mosh`.
- Dependency changes must keep every license GPLv3-compatible, and every
  pinned revision anonymously fetchable (release publishing verifies this).
- Do not include real hostnames, IP addresses, usernames, keys, or other
  personal data in code, tests, fixtures, or screenshots.
