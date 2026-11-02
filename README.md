# Free Lunch

Free, open-source (GPL-3.0-or-later, with an
[App Store exception](LICENSE-APP-STORE-EXCEPTION.md)) personal health
timeline for iPhone and Apple Watch: plate-based food logging with a kitchen
scale, an honest energy-balance engine that pauses rather than guesses, and
weight and medication lanes on one timeline. A sibling of
[Burly](https://github.com/dfakkeldy/burly), sharing its architecture.

Under active development; nothing here is ready to use yet.

## Layout

- `FreeLunchKit/`: Swift package holding the logic and its tests.
  - `FLCore`: domain value types and canonical units.
  - `FLEnergyCore`: the energy-balance engine (pure functions, no storage).
  - `FLPlate`: plate logging logic (typeahead, scale sessions, AI capture core).
  - `FLPersistence`: the SwiftData schema and the store boundary.
  - `FLFixtures`: synthetic test data. Real health data never enters this repo.

## Commands

```bash
cd FreeLunchKit && swift test
```

## Privacy

Everything stays on the device. Photos leave it only inside an AI request the
user explicitly chooses to make.
