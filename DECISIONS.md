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

## 2026-11-03 — Next-dose projection and the overdue boundary

- `NextDose.nextDoseAt` adds the active profile's `intervalDays` as calendar
  days, in the injected `Calendar` and its time zone, to the latest shot's
  `takenAt`. The latest shot is the one with the greatest `takenAt`, so an
  edited `takenAt` counts and a late shot moves every later projection.
  Shots sharing the latest `takenAt` project the same date, so which one is
  picked does not matter. Across a daylight-saving change the wall-clock time
  is kept.
- A projection landing in the skipped spring-forward hour moves forward by
  that hour (02:30 becomes 03:30), and one landing in the repeated fall-back
  hour takes the first occurrence. Tests pin both.
- Overdue begins strictly after the projected instant. At exactly
  `nextDoseAt` the dose is due today; one second later it is overdue with
  `daysLate` 0. Overdue does not wait for the end of the calendar day, so
  the card, the complication and the planner's reminder share one boundary.
  `daysLate` counts calendar days from the due date to today.
- No projection without an active profile, for an archived profile, with no
  shots for that profile, or with a non-positive interval. Shots of other
  profiles never count.

## 2026-11-03 — Watch sync spine

The Burly sync pattern, ported into `FreeLunchKit`. Its one schema change
is the phone's applied-outbox ledger, appended to the unshipped V2.

- **Acks are their own message.** Burly carries acks inside the digest
  and keeps a retained ack set on the phone. Free Lunch sends an ack per
  applied outbox record on the ordered channel instead, and acks every
  delivery, duplicates included. The watch prunes only on an ack.
- **The phone keeps an applied-id ledger, checked first.** Retransmissions
  are routine: a relaunched watch resends its outbox on activation before
  it reads an ack still waiting for it, so a copy can land after the user
  has deleted the record on the phone. Without stored state that copy
  inserts the record again. So the phone store keeps one
  `AppliedOutboxRecord` per applied `WatchOutboxItem.id` (unique id plus
  the applied-at date), appended to `FreeLunchSchemaV2`; the watch store
  refuses the ledger operations. `PhoneSyncCoordinator` owns the check,
  behind the `AppliedOutboxLedger` protocol with the SwiftData phone store
  as the production conformer: an id already in the ledger is acked
  without reaching the applier; otherwise it applies, records the id, then
  acks. If recording fails after a successful apply it throws and sends no
  ack, so the watch resends. Closing this at the spine rather than in
  each applier covers every outbox kind with one rule.
- **Ledger rows are kept forever.** One small row per applied outbox item
  (shots and meals reuse their record's id, so one row each; every hunger
  edit has its own id and row), never pruned: a retransmission can arrive after any delay (a watch left
  off for weeks still holds its unacked outbox), so no age is safe to
  forget.
- **First copy wins in the applier too.** A crash or failed record between
  apply and record means the next copy reaches the applier again, so the
  applier still inserts a shot or meal only when no row with its id exists
  and otherwise does nothing, which keeps a phone edit made in between.
  A phone delete made in between is not kept: apply and record are two
  saves, so a crash or failed save after the apply leaves the row with no
  ledger entry, and if the user deletes it before the watch resends, the
  resend inserts it again. That needs a failure at that exact point, so it
  is accepted for now; closing it means applying and recording in one
  save, which the store API does not offer yet.
  One gap is still left to the phone-side applier: hunger edits must keep
  the latest `editedAt` per meal, which MealEntry does not store.
- **Outbox records are immutable once queued.** An ack names an id, not a
  version, and a queued transfer cannot be recalled. A coalesced append
  or an undo after a record was sent has to be a new record with its own
  id; editing the queued one in place would let the old copy's ack prune
  the new one.
- **Every activation resends the whole unacked outbox.** WatchConnectivity
  drops a transfer from its outstanding list once the other device has it,
  even if the app there has not consumed it, so a watch that comes forward
  several times before the phone app runs queues several copies. The
  ledger acks the extra copies without applying them; a resend backoff can
  come later if the transfer budget calls for it.
- **The glance lives in the transport.** Next dose and today-remaining
  ride the latest-wins digest (WatchConnectivity's application context,
  which the system retains across relaunches), so the watch keeps them in
  memory and re-reads them on activation. Only the recent foods are stored,
  as before.
- **No weight glance yet.** The digest carries recent foods, the next
  dose and today's remaining. The watch root's read-only weight glance
  (trend and last weigh-in) also reads from the digest, so the watch root
  work adds it as an optional field. An older peer ignores the new key and
  a newer one reads a missing key as nil, so the codec format stays 1.
- **Ranking is the typeahead's.** The digest's foods are
  `Typeahead.rows(query: "")` taken to 200, not a second sort, so the
  wrist list cannot drift from the phone's empty-query list.
- **Placement.** Digest values are `FLCore` DTOs, the builder is in
  `FLPlate`, and the transport protocol, coordinators, in-memory link and
  WatchConnectivity adapter are in `FLPersistence`. No dependency edge was
  added. The adapter compiles only where WatchConnectivity exists; the
  rules it carries out are tested on the host over the in-memory link.

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

## 2026-11-03 — No tab bar on the plate

The plate screen is pushed from the Timeline tab and hides the tab bar, so
it keeps the whole screen as it did before the app had tabs. To switch tabs
from a plate, go back to the timeline first; the draft stays open there.

The scale-session UI tests depend on this. Their `reveal()` helper drags
from 78% down the plate list's frame, and at the largest accessibility text
size a visible tab bar puts that point on the list's bottom inset rather
than on its rows, so the drag scrolls nothing. Showing the tab bar on the
plate later means starting that drag from the visible part of the list
instead. `AppShellUITests` checks that the plate has neither the bar nor
the settings gear.

## 2026-11-03 — The HealthKit adapter

The first HealthKit code: body weight only, in `FLPersistence/Health/`.

- **Protocol in front, adapter in the package.** `HealthStoreAdapter` keeps
  every HealthKit type out of the logic, so `HealthWeightSync` (anchored
  mirror sync, weigh-in writes, access status) is tested on the macOS host
  against a mock. The real `HealthKitStoreAdapter` sits beside it in the
  package, behind `#if os(iOS) || os(macOS)`, rather than in the phone
  target, so adding it changes no app-target file. It was first guarded by
  `#if canImport(HealthKit)`, which is also true on watchOS; once the sync
  spine put the watch's half in `FLPersistence`, the watch may link the
  package, so watchOS is now excluded by name: no HealthKit write path can
  reach the watch binary (spec §9, the phone is the only writer). macOS
  stays in so `swift test` type-checks the adapter on the Mac host; macOS
  is a test host only, never shipped.
- **The query anchor lives outside SwiftData.** An anchor is a resumable
  cursor, not user data, so it goes behind `HealthAnchorStore` (default:
  `UserDefaults`, one value per type) instead of into the versioned schema.
  Each page applies additions, then deletions, then stores its anchor, so a
  failure replays the page next time; replays are idempotent. Losing the
  anchor only means a fresh backfill from the start of history, though a
  backfill re-delivers live samples only: a deletion made after the lost
  anchor isn't replayed, so `resyncFromStart` catches up from the stored
  anchor before it forgets it.
- **The anchor outlives the store.** It sits in `UserDefaults` and the
  mirror in SwiftData, so a store that is ever recreated (a reset or a
  migration fallback; none exists yet) must forget the body-mass anchor
  too, or the next sync resumes past every sample and the mirror stays
  empty. Any such path calls `resyncFromStart` or clears the anchor.
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
  prompts from a sync. A locked device (`temporarilyUnavailable`) degrades
  the same way.
- **A denied read still moves the anchor.** A pass that runs while reading
  is off stores an anchor past samples HealthKit hid, and an anchored query
  never delivers them again. So `requestAccess` forgets the anchor after
  the sheet, and `resyncFromStart` is the entry point for the Settings
  backfill row once the user turns reading on in the Health app (the sheet
  never shows twice). The mock models HealthKit's hiding; the real
  behaviour can only be checked on a device.
- **"Own" has one definition.** The adapter reports the source bundle it
  writes under (`HKSource.default()` in the real one); `canModify` compares
  against that, and `deleteWeight` finds a sample by UUID alone and throws
  `importedRecordImmutable` if another source holds it, rather than treating
  it as already deleted.
- **One pass at a time.** An overlapping `sync` joins the running pass, so
  two passes can't interleave pages, regress the anchor or re-surface a
  deleted row.
- **Keeping current** is an incremental sync from the stored anchor, run by
  the caller. Observer queries and background delivery are not wired yet.
- **Dietary types** join as new `HealthDataType` cases with their own
  adapter methods and sync service; anchors and status are already keyed by
  type.

## 2026-11-03 — Weight gate: both-ends reading settled

Product decision: keep the stricter reading recorded as under review on
2026-11-02 (#7). "Trend defined" means defined at both ends of the 21-day
window: just before its first day and at the end of yesterday. Δtrend needs
both ends, and a shorter span divided by 21 would show a number the data does
not support. A fresh user with complete logging and a weigh-in every day from
day 0 gets the first estimate on day 27 (the trend itself is undefined until
the sixth weigh-in), and `.paused(.insufficientWeight)` on day 26. A golden
test pins both days and the guard carries a doc comment. No behaviour change.

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
  (#7). Settled 2026-11-03, see the entry above.** Δtrend is the trend just
  before the window's first day subtracted from the trend at the end of
  yesterday, so the estimator pauses with `.insufficientWeight` until both
  ends exist. This is stricter than the per-day completeness check alone:
  a new user's first estimate needs about 26–27 days of history rather
  than 22. The alternatives (a shorter span divided by 21, or a smaller
  divisor) would show a number the data does not support. Changing the
  reading later is a small change to one guard and the golden expectations.

## 2026-11-01 — Package shape

`FreeLunchKit` declares all five v1 targets on day one so parallel feature
work adds files rather than editing the target list. `FLEnergyCore` is
dependency-free so the energy math can be verified alone; `FLPersistence` is
the only target that imports SwiftData. Bundle IDs are
`com.freelunch.nutrition` and `com.freelunch.nutrition.watchkitapp`,
following the Echo and Burly convention.
