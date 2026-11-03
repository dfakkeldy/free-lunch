# Decisions

Newest first. Product decisions live in the private planning repo; this log
records the code-level choices made here.

## 2026-11-03 — Exposure curve math

- `ExposureCurve` (FLCore) sums one Bateman curve per logged shot, scaled
  by its dose, and returns percent of a steady-state peak. Nothing else
  leaves it: no absolute level is exposed.
- `ka` is solved by bisection on `log1p(x) / x = ke·tmax` with
  `x = ka / ke − 1`, iterated until the midpoint stops moving in Double. A
  profile whose tmax is not below `halfLifeHours / ln 2` has no such `ka`
  and is rejected rather than clamped.
- 100% is the closed-form steady-state peak of a never-miss schedule at the
  latest logged shot's dose and the profile's interval. One reference covers
  the whole curve, so earlier lower-dose weeks read below 100%. Values are
  not capped; a shorter spacing than the interval can exceed 100%.
- Golden vectors come from `Scripts/exposure-curve-golden.py`, which works
  in 50-digit decimal, solves `ka` by Newton's method and finds the
  reference by brute-force superposition, so it shares no method with the
  Swift code.

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
