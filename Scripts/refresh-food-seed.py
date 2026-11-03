#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check or refresh the food seed's nutrition values against USDA FoodData Central.

FreeLunchKit/Sources/FLCore/Resources/food-seed.json lists each food with its
FDC id. This script reads the full FDC record for every id (20 per request,
read-only) and compares the seed's per-100 g kcal, protein, carbs, fat and fiber
with FDC's own numbers: nutrients 208, 203, 205, 204 and 291.

  Scripts/refresh-food-seed.py            report differences, change nothing
  Scripts/refresh-food-seed.py --write    rewrite differing values in the seed
  Scripts/refresh-food-seed.py --records-file records.json
                                          read a saved FDC response instead of
                                          calling the API (a JSON array of
                                          full-format food records)

The API key comes from FDC_API_KEY (default DEMO_KEY, which is limited to a
handful of requests per hour; a free key from api.data.gov lifts that).

Only the five values are ever rewritten. Keys, names, servings and `since` are
left alone, and a shipped entry's key is permanent. Once a build containing the
seed has shipped, do not --write: devices already hold the old values and the
loader never overwrites a stored row; ship a correction as a new key instead.
"""
import argparse
import json
import os
import sys
import urllib.parse
import urllib.request
from pathlib import Path

SEED = Path(__file__).resolve().parent.parent / "FreeLunchKit/Sources/FLCore/Resources/food-seed.json"
NUTRIENTS = {"kcal": "208", "proteinG": "203", "carbsG": "205", "fatG": "204", "fiberG": "291"}
BATCH = 20


def fetch(ids, api_key):
    query = urllib.parse.urlencode({"fdcIds": ",".join(map(str, ids)), "format": "full", "api_key": api_key})
    with urllib.request.urlopen(f"https://api.nal.usda.gov/fdc/v1/foods?{query}", timeout=60) as response:
        return json.load(response)


def fdc_values(record):
    by_number = {n["nutrient"]["number"]: n.get("amount") for n in record["foodNutrients"] if "nutrient" in n}
    return {key: by_number.get(number) for key, number in NUTRIENTS.items()}


def tidy(value):
    return int(value) if value is not None and float(value) == int(value) else value


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--write", action="store_true", help="rewrite differing values in the seed file")
    parser.add_argument("--records-file", help="read FDC records from this JSON file instead of the API")
    args = parser.parse_args()

    seed = json.loads(SEED.read_text())
    foods = seed["foods"]
    if args.records_file:
        records = json.loads(Path(args.records_file).read_text())
    else:
        api_key = os.environ.get("FDC_API_KEY", "DEMO_KEY")
        records = []
        for start in range(0, len(foods), BATCH):
            records += fetch([f["fdcId"] for f in foods[start:start + BATCH]], api_key)
    by_id = {record["fdcId"]: record for record in records}

    differing = missing = 0
    for food in foods:
        record = by_id.get(food["fdcId"])
        if record is None:
            missing += 1
            continue
        fresh = fdc_values(record)
        changes = {k: (food.get(k), tidy(v)) for k, v in fresh.items() if food.get(k) != tidy(v) and v is not None}
        if changes:
            differing += 1
            print(f"{food['key']} (fdcId {food['fdcId']}): " + ", ".join(f"{k} {a} -> {b}" for k, (a, b) in changes.items()))
            if args.write:
                food.update({k: b for k, (_, b) in changes.items()})
    print(f"checked {len(foods) - missing} of {len(foods)} foods: {differing} differ from FDC")
    if args.write and differing:
        lines = ",\n".join(json.dumps(f, ensure_ascii=False) for f in foods)
        head = json.dumps(seed["source"], ensure_ascii=False)
        SEED.write_text(f'{{\n"source": {head},\n"seedVersion": {seed["seedVersion"]},\n"foods": [\n{lines}\n]\n}}\n')
        print("seed file rewritten")
    return 1 if differing and not args.write else 0


if __name__ == "__main__":
    sys.exit(main())
