# Decisions

Newest first. Product decisions live in the private planning repo; this log
records the code-level choices made here.

## 2026-11-03 — Dose-period report boundaries and counts

- **Placement is by instant, not calendar day**, using the convention
  `DosePeriod` already has: `[start, end)` for a closed period, `[start, end]`
  for the open one (`DosePeriod.contains`). On the day a strength changes, a
  meal or side effect stamped before the shot is in the old period; one at or
  after it is in the new period. Records before the first shot or after
  the open period's end are in no period. That end is `asOf`, or the last
  shot when it is stamped later, so membership always matches the span the
  duration, coverage and trend are computed over.
- **Hunger**: unit is a logged meal placed by `loggedAt`. No hunger is
  unknown and counted as such, never imputed; the mean is nil with no
  ratings. An out-of-range stored value is treated as unknown, not rated.
  A rating on a draft (including one a watch hunger quick-log created) is
  not counted until the draft is logged; whether unlogged watch ratings
  should count is an open product question. Logged meals imported from
  Apple Health have no rating and count as unknown.
- **Side effects** are counted by `SideEffectType` as stored; `.other` is
  keyed by its exact text. No correlation output anywhere.
- **Trend at a boundary** is the §3 trend held from the latest weigh-in at or
  before that instant (a weigh-in stamped exactly on the boundary counts). A
  boundary with no weigh-in that day carries the last trend forward, however
  old; the change is nil only while no trend is defined. The report does not
  yet expose how stale that held value is.
- **Where it lives**: counts and the report type are in `FLCore`
  (`DosePeriodReports`, trend passed as a closure); `FLPersistence` is the only
  target that sees both `FLCore` and `FLEnergyCore`, so the binding to a
  `TrendSeries` is there.

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
