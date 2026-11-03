# Decisions

Newest first. Product decisions live in the private planning repo; this log
records the code-level choices made here.

## 2026-11-03 — Food catalog seed (spec §11)

- **Seed shape.** About 300 generic whole foods ship as
  `FLCore/Resources/food-seed.json`, declared as a resource of the existing
  `FLCore` target (no new target). Values are per 100 g, copied from USDA
  FoodData Central SR Legacy records (public domain); each entry carries its
  `fdcId` and data type. `kcal` is FDC nutrient 208 as published. Servings
  are household measures chosen for logging convenience, not FDC columns.
- **Value precision.** The FDC API's search and abridged responses round
  values to three significant figures (31.0 where the full record says
  31.02), and the key used for this first pass had a small hourly and daily
  quota. The ten pinned staples and ten random entries were checked against
  the full FDC records and now carry the full-precision numbers; the rest hold
  the three-figure values (largest difference seen across the 20 checked
  entries: 0.05 g per 100 g). `Scripts/refresh-food-seed.py` compares every
  entry with its full FDC record and, with `--write`, tightens the values.
  Run it with a normal api.data.gov key before the first release that
  contains the seed; after that, corrections ship as new keys.
- **Identity, not bookkeeping.** A seeded food's id is a name-based (v5) UUID
  of its stable `key`, so the loader's only rule is "insert the entries whose
  id is not in the store". That makes a load idempotent, makes a version bump
  insert only the new keys, and means an archived or forked seeded row (which
  keeps its id) is never resurrected. No schema change and no stored seed
  version. The namespace UUID and every shipped `key` are permanent. This
  rests on catalog foods being archived, never deleted, seeded or not: a
  deleted seeded row would be inserted again at the next launch, so any
  later delete must archive or refuse seeded ids.
- **Additive bumps.** A bump adds entries stamped with the new `since`
  version. A shipped entry is never edited in place: a device that holds the
  row would keep the old value anyway, so a correction ships as a new key.
  The seed's names are unique, so the corrected entry also needs a distinct
  name, or the old entry leaves the file. Either way, a device that already
  holds the old row keeps it visible; hiding it would need a retire list,
  which does not exist yet.
- **Fork on edit.** `FoodCatalogStore.editFood` is the edit path for catalog
  foods. A `.seeded` food is never changed: a real edit creates a `.custom`
  food with the edits and archives the original in one save. The fork copies
  `useCount`, `lastUsedAt` and `lastPortionGrams` so a food the user already
  relies on keeps its typeahead rank. An edit that changes nothing creates no
  fork. `updateFood` refuses a `.seeded` row, and refuses to make a row
  `.seeded`, with `seededFoodImmutable`, so the fork is the only way a
  seeded food changes. A row is `.seeded` only from creation (the loader).
- **Loading.** The phone app applies the bundled seed each time it opens
  its on-disk store; the loader adds only the missing keys. UI tests' in-memory
  stores skip it so their synthetic catalog stays exact. A failed load shows
  an error and leaves the log usable.
- **Liquids.** `isLiquid` only switches the display unit to ml; quantities
  stay grams. It is set for drinks, milk and cream, whose density is close
  to 1, and not for oils, syrups or soy sauce, whose grams would read as a
  visibly wrong ml figure.
- **Ranking.** Seeded foods are ordinary never-used foods to `Typeahead`, so
  they sit in the prefix and substring tiers below anything with history, and
  the empty query never shows them. The §2 typeahead fixture is extended with
  the whole seed rather than given special cases.

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
  calendar day. The stored `day` is a key for the civil day (its Gregorian
  year, month and day at midnight UTC), not the instant the day started where
  it was marked, so a time-zone change neither moves a mark to another day
  nor hides it from unmarking. Readers get it back as the start of that day
  in their own calendar. Marking twice changes nothing. Activation dates and
  `TargetPeriod.startDate` still store a start-of-day instant; they are not
  changed here.
- **Activation starts today or later.** `activateFormula` takes today and
  refuses an earlier day, even from the default schedule, so a settings write
  cannot rewrite rendered history. Replacing the whole schedule is internal;
  the labeled re-run history action stays the only retroactive path.
- **α is validated at the store boundary.** The setter takes the raw number
  and refuses anything outside 0.05 to 0.25 or NaN before touching a row;
  loading validates every field again and refuses a damaged row.
- **Recompute is a diff, not a call site.** `EnergyRecomputeCoordinator`
  rebuilds the key after each settings write and runs the engine only when
  `EnergyRecomputeReason.reasons` is non-empty, so a real change costs one
  recompute however many reasons it reports, and a write that changes no input
  costs none. The computation is injectable so tests count real runs. The
  re-adoption suggestion reads the target ledger, which is not in the key,
  so a refresh with an unchanged key re-reads the open period and updates
  the suggestion without running the engine.
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
