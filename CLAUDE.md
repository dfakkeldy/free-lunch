# Free Lunch

Public GPL-3.0-or-later repo (with an App Store exception) for the Free Lunch
iPhone + Apple Watch app. Sibling of Burly (`~/Developer/burly`), whose
architecture and harness it inherits.

## Layout

- `FreeLunchKit/`: Swift package; most logic and every test lives here.
  Targets are pre-declared in `Package.swift`. Add files, not targets.
- `DECISIONS.md`: decision log for this repo, newest entry first.

## Commands

```bash
cd FreeLunchKit && swift test
```

On Dan's Mac, run agent-started builds and tests through
`~/.claude/bin/xcode-build-slot.sh -- <command>`.

## Rules

- Source files start with `// SPDX-License-Identifier: GPL-3.0-or-later`.
- Tests use Swift Testing (`import Testing`), not XCTest.
- Canonical units only in storage: grams, kilograms, kcal, milligrams.
- `FLEnergyCore` has no dependencies. Keep it that way: it is verified by
  golden vectors in isolation.
- This repo is public. Planning and the full spec live in a private local
  repo; never copy personal health details, real data or planning notes here.
  Fixtures are synthetic.
