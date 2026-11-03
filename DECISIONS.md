# Decisions

Newest first. Product decisions live in the private planning repo; this log
records the code-level choices made here.

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
- **Ledger rows are kept forever.** One small row per watch-logged record,
  never pruned: a retransmission can arrive after any delay (a watch left
  off for weeks still holds its unacked outbox), so no age is safe to
  forget.
- **First copy wins in the applier too.** A crash or failed record between
  apply and record means the next copy reaches the applier again, so the
  applier still inserts a shot or meal only when no row with its id exists
  and otherwise does nothing, which keeps a phone edit made in between.
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
