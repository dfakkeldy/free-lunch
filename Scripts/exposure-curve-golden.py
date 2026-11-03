#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Golden vectors for the exposure curve (spec section 5, acceptance #2).

Usage:
    python3 Scripts/exposure-curve-golden.py <fixture> <halfLifeHours> <tmaxHours> <intervalDays>

    python3 Scripts/exposure-curve-golden.py semaglutide 168 36 7
    python3 Scripts/exposure-curve-golden.py tirzepatide 120 24 7

Pass the population prefills that KnownMedication ships in
FreeLunchKit/Sources/FLCore/MedicationProfileData.swift. The printed lines are
pasted into FreeLunchKit/Tests/FLCoreTests/ExposureCurveTests.swift.

The numbers are derived here without reading the Swift implementation, and
by different methods where a choice exists:

- Arithmetic is decimal at 50 significant digits (standard library only).
- ka is found by Newton's method on F(ka) = ln(ka/ke) - tmax * (ka - ke),
  started to the right of the root (Swift bisects a rescaled form).
  F is concave with F(ke) = 0, so from a point where F < 0 the iterates
  fall monotonically onto the root with ka > ke, never onto ka = ke.
- The steady-state reference is found by brute force: a never-miss
  superposition long enough that the omitted tail is below 1e-45, maximised
  over one interval by golden-section search (Swift uses the closed form).
  The closed form is also evaluated here and the two must agree.

Model: each logged shot i at time t_i with dose d_i contributes
d_i * (exp(-ke (t - t_i)) - exp(-ka (t - t_i))) for t > t_i and nothing
before. The constant ka / (ka - ke) of the Bateman function multiplies the
curve and the reference alike, so it is left out. The output is
100 * exposure / reference, where the reference is the steady-state peak of
a never-miss schedule at the latest shot's dose and the profile interval.
No absolute level is computed or printed.

Every fixture is synthetic. Times are hours from the fixture anchor.
"""
import sys
from decimal import Decimal, getcontext

getcontext().prec = 50

ZERO = Decimal(0)
ONE = Decimal(1)
TWO = Decimal(2)

# (day, dose) pairs. Mirrors the shot lists in FLFixtures: the semaglutide
# series is DosePeriodFixtures.shots, the tirzepatide one is
# ExposureCurveFixtures.tirzepatideShots.
FIXTURES = {
    # 0.25 x4 on schedule, 0.5 with day 42 missed, then 1.0 every 6 days.
    "semaglutide": {
        "shots": [
            ("0", "0.25"), ("7", "0.25"), ("14", "0.25"), ("21", "0.25"),
            ("28", "0.5"), ("35", "0.5"), ("49", "0.5"), ("56", "0.5"),
            ("63", "1.0"), ("69", "1.0"), ("75", "1.0"), ("81", "1.0"),
        ],
        "sample_hours": [
            "-24", "0", "36", "168", "240", "672", "1008", "1092", "1176",
            "1512", "1980", "2016", "2184", "2520",
        ],
    },
    # 2.5 x4 on schedule, 5.0 with day 42 missed and a shot 30 h late.
    "tirzepatide": {
        "shots": [
            ("0", "2.5"), ("7", "2.5"), ("14", "2.5"), ("21", "2.5"),
            ("28", "5"), ("35", "5"), ("49", "5"), ("57.25", "5"),
            ("63", "5"),
        ],
        "sample_hours": [
            "0", "24", "168", "504", "696", "1008", "1152", "1200", "1374",
            "1398", "1536", "1680", "2016",
        ],
    },
}


def solve_ka(ke, tmax):
    """Newton on F(ka) = ln(ka/ke) - tmax (ka - ke), from the right."""
    if not (ZERO < ke * tmax < ONE):
        raise ValueError("no ka > ke peaks at this tmax")

    def f(ka):
        return (ka / ke).ln() - tmax * (ka - ke)

    ka = TWO / tmax
    while f(ka) >= 0:
        ka *= 2
    for _ in range(200):
        step = f(ka) / (ONE / ka - tmax)
        ka -= step
        if abs(step) < Decimal("1e-45") * ka:
            break
    assert ka > ke
    assert abs((ka / ke).ln() / (ka - ke) - tmax) < Decimal("1e-40")
    return ka


def unit_shot(ke, ka, hours):
    if hours <= 0:
        return ZERO
    return (-ke * hours).exp() - (-ka * hours).exp()


def golden_max(func, lo, hi, iterations=170):
    """Golden-section search for the maximum of a unimodal function."""
    inv_phi = (Decimal(5).sqrt() - 1) / 2
    a, b = lo, hi
    c = b - inv_phi * (b - a)
    d = a + inv_phi * (b - a)
    fc, fd = func(c), func(d)
    for _ in range(iterations):
        if fc > fd:
            b, d, fd = d, c, fc
            c = b - inv_phi * (b - a)
            fc = func(c)
        else:
            a, c, fc = c, d, fd
            d = a + inv_phi * (b - a)
            fd = func(d)
    x = (a + b) / 2
    return x, func(x)


def steady_state_peak(ke, ka, interval_hours):
    """Peak of a converged never-miss superposition, unit dose."""
    count = 1
    while (-ke * interval_hours * count).exp() > Decimal("1e-45"):
        count += 1

    def train(offset):
        return sum(
            unit_shot(ke, ka, offset + n * interval_hours) for n in range(count)
        )

    offset, peak = golden_max(train, ZERO, interval_hours)

    # Closed form of the same sum, as a cross-check.
    a = ONE - (-ke * interval_hours).exp()
    b = ONE - (-ka * interval_hours).exp()
    closed_offset = (ka * a / (ke * b)).ln() / (ka - ke)
    closed_peak = (-ke * closed_offset).exp() / a - (-ka * closed_offset).exp() / b
    assert abs(closed_offset - offset) < Decimal("1e-12"), (closed_offset, offset)
    assert abs(closed_peak - peak) < Decimal("1e-30"), (closed_peak, peak)
    return offset, peak


def main(argv):
    if len(argv) != 5 or argv[1] not in FIXTURES:
        sys.exit(__doc__)
    name = argv[1]
    half_life = Decimal(argv[2])
    tmax = Decimal(argv[3])
    interval_hours = Decimal(argv[4]) * 24

    ke = TWO.ln() / half_life
    ka = solve_ka(ke, tmax)

    single_peak_hours, _ = golden_max(
        lambda h: unit_shot(ke, ka, h), ZERO, 10 * tmax
    )
    assert abs(single_peak_hours - tmax) < Decimal("1e-12")

    shots = [(Decimal(day) * 24, Decimal(dose)) for day, dose in FIXTURES[name]["shots"]]
    latest_dose = max(shots)[1]
    offset, unit_peak = steady_state_peak(ke, ka, interval_hours)
    reference = latest_dose * unit_peak

    print(f"// {name}: halfLifeHours {argv[2]}, tmaxHours {argv[3]}, intervalDays {argv[4]}")
    print(f"// ke {ke:.15e} /h, ka {ka:.15e} /h")
    print(f"// single-dose peak at {single_peak_hours:.12f} h")
    print(f"// steady-state peak {offset:.12f} h after each shot, dose {latest_dose}")
    for raw in FIXTURES[name]["sample_hours"]:
        hours = Decimal(raw)
        exposure = sum(dose * unit_shot(ke, ka, hours - at) for at, dose in shots)
        percent = 100 * exposure / reference
        print(f"({raw}, {percent:.12f}),")


if __name__ == "__main__":
    main(sys.argv)
