# Decisions

Newest first. Product decisions live in the private planning repo; this log
records the code-level choices made here.

## 2026-11-03 — The HealthKit adapter

The first HealthKit code: body weight only, in `FLPersistence/Health/`.

- **Protocol in front, adapter in the package.** `HealthStoreAdapter` keeps
  every HealthKit type out of the logic, so `HealthWeightSync` (anchored
  mirror sync, weigh-in writes, access status) is tested on the macOS host
  against a mock. The real `HealthKitStoreAdapter` sits beside it behind
  `#if canImport(HealthKit)` rather than in the phone target: it compiles
  in `swift test` too, and adding it changes no app-target file. Only the
  phone app links `FLPersistence`, so no HealthKit write path is reachable
  from the watch (spec §9).
- **The query anchor lives outside SwiftData.** An anchor is a resumable
  cursor, not user data, so it goes behind `HealthAnchorStore` (default:
  `UserDefaults`, one value per type) instead of into the versioned schema.
  Each page applies additions, then deletions, then stores its anchor, so a
  failure replays the page next time; replays are idempotent. Losing the
  anchor only means a fresh backfill from the start of history.
- **Write order.** A manual weigh-in is saved to HealthKit first; the mirror
  row is built from the sample HealthKit saved. Editing an own weigh-in
  saves the replacement before deleting the original, so a failure can
  leave a duplicate but never lose a weigh-in. Other sources' samples are
  refused (`importedRecordImmutable`) before HealthKit is touched; they take
  a Correction.
- **Access is write status only.** HealthKit hides read authorization, so
  Settings shows write status per type plus whether a re-request would show
  the sheet. A denied read is an empty history; denied or missing access
  degrades (`HealthSyncResult.degraded`, `HealthAccessError`) and never
  prompts from a sync.
- **Keeping current** is an incremental sync from the stored anchor, run by
  the caller. Observer queries and background delivery are not wired yet.
- **Dietary types** join as new `HealthDataType` cases with their own
  adapter methods and sync service; anchors and status are already keyed by
  type.

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
