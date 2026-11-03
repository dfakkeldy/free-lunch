# Decisions

Newest first. Product decisions live in the private planning repo; this log
records the code-level choices made here.

## 2026-11-03 — Energy settings have a persisted home

The settings `EnergyBinding.recompute` reads (formula activation schedule,
rate goal, trend α, adoption mode, "didn't track" marks) were passed in by
its caller, so nothing survived a relaunch. They now live in the phone store.
V2 had no entity that fits (FormulaVersion is an immutable registry row with
no activation date; TargetPeriod is an adopted number), so two entities are
appended to FreeLunchSchemaV2, which has not shipped. The V1 to V2 stage
stays lightweight.

- **One settings row.** `EnergySettingsRecord` has a constant unique key and
  is absent until the first write; a store with no row reads as the spec
  defaults (α 0.10, maintenance rate, suggest-only adoption, builtin formula
  active from the start). Reading never creates it.
- **The schedule is JSON on that row**, as `FormulaVersion.paramsJSON` is.
  Activations still hold a formula by value, the same by-value pinning the
  target ledger uses today; linking them to FormulaVersion rows is the
  registered-formula work that already tracks that.
- **Marks are rows, not a setting.** `DidNotTrackMark` is one row per
  calendar day (the start of the day in the calendar it was marked in).
  Marking twice changes nothing.
- **α is validated at the store boundary.** The setter takes the raw number
  and refuses anything outside 0.05 to 0.25 or NaN before touching a row;
  loading validates every field again and refuses a damaged row.
- **Recompute is a diff, not a call site.** `EnergyRecomputeCoordinator`
  rebuilds the key after each settings write and runs the engine only when
  `EnergyRecomputeReason.reasons` is non-empty, so a real change costs one
  recompute however many reasons it reports, and a write that changes no input
  costs none. The computation is injectable so tests count real runs.
- **α cannot flip a pause state under `FL-EB v1`.** Trend definedness (three
  samples over five days) does not depend on α, so a change of α moves the
  estimate but not the tracking or paused state. Spec section 6 acceptance 3
  asks for a state flip; the test asserts the cascade through the changed
  estimate instead.

## 2026-11-03 — Flat 7-day default dosing interval

- Every `MedicationProfileData` prefill uses `defaultIntervalDays` (7),
  liraglutide included. There are no per-drug interval defaults.
- The interval is edited per profile (`intervalDays`). Tests in `FLCoreTests`
  pin the default for the three known medications and a custom profile.
- No change to dose-period derivation or stored data.

## 2026-11-02 — Unit factors, target warnings and the weight gate

Recorded from the first build's pull requests, which flagged these for the
log.

- **Exact imperial factors (#3).** Foundation rounds the pound and stone
  (0.453592 and 6.35029 kg). `FLCore` converts lb, oz and st with the exact
  avoirdupois definitions instead: 1 lb = 0.45359237 kg, oz = lb ÷ 16,
  st = 14 lb, for both input and display. Every other unit goes through
  Foundation. Weights entered in pounds therefore round-trip exactly.
- **Adoption warnings are a union (#12).** Spec §3 words the floor and rate
  rails on the calculated target. At adoption the app returns the calculated
  target's warnings plus the rails applied to the adopted number, so
  adjusting 1300 down to 1100 warns, and so does adjusting 1100 up to 1300.
  Warnings never block a save.
- **Weight completeness reads "trend defined" at both ends of the window
  (#7). Under review.** Δtrend is the trend just before the window's first
  day subtracted from the trend at the end of yesterday, so the estimator
  pauses with `.insufficientWeight` until both ends exist. This is stricter
  than the per-day completeness check alone: a new user's first estimate
  needs about 26–27 days of history rather than 22. The alternatives
  (a shorter span divided by 21, or a smaller divisor) would show a number
  the data does not support. Changing the reading later is a small change to
  one guard and the golden expectations.

## 2026-11-01 — Package shape

`FreeLunchKit` declares all five v1 targets on day one so parallel feature
work adds files rather than editing the target list. `FLEnergyCore` is
dependency-free so the energy math can be verified alone; `FLPersistence` is
the only target that imports SwiftData. Bundle IDs are
`com.freelunch.nutrition` and `com.freelunch.nutrition.watchkitapp`,
following the Echo and Burly convention.
