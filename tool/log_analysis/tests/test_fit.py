import math
from pathlib import Path

import pytest

from didscout_logs.fit import Alias, Feature, fit_candidates, fit_line, select_readings
from didscout_logs.sessions import Session, load_session
from tests.synthetic import BASE_MS, SessionLog


def test_fit_line_recovers_an_exact_line() -> None:
    xs = [float(x) for x in range(10)]
    line = fit_line(xs, [2 * x + 3 for x in xs])
    assert line is not None
    assert line.slope == pytest.approx(2)
    assert line.intercept == pytest.approx(3)
    assert line.r == pytest.approx(1)
    assert line.max_error == pytest.approx(0, abs=1e-9)


def test_fit_line_percentile_is_nearest_rank() -> None:
    xs = [float(x) for x in range(10)]
    noise = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.5, -0.5]
    ys = [x + e for x, e in zip(xs, noise, strict=True)]
    line = fit_line(xs, ys)
    assert line is not None
    residuals = sorted(
        abs(y - (line.slope * x + line.intercept)) for x, y in zip(xs, ys, strict=True)
    )
    assert line.p90_error == residuals[8]
    assert line.max_error == residuals[9]
    assert line.p90_error < line.max_error


def test_fit_line_needs_varying_x() -> None:
    assert fit_line([1.0, 1.0, 1.0], [1.0, 2.0, 3.0]) is None
    assert fit_line([1.0], [1.0]) is None


def test_fit_line_with_constant_values_has_undefined_r() -> None:
    line = fit_line([1.0, 2.0, 3.0], [5.0, 5.0, 5.0])
    assert line is not None
    assert math.isnan(line.r)
    assert line.slope == 0


@pytest.mark.parametrize(
    ("feature", "offset", "expected"),
    [
        (Feature.U8, 1, 0xFE),
        (Feature.U16, 0, 0x01FE),
        (Feature.S16, 1, 0xFE80 - 0x10000),
    ],
)
def test_feature_read_is_big_endian(feature: Feature, offset: int, expected: int) -> None:
    assert feature.read(bytes([0x01, 0xFE, 0x80]), offset) == expected


def _session(tmp_path: Path) -> Session:
    """A DID sampled every 10 s whose bytes 1-2 hold value*10+500."""
    log = SessionLog("aaaa0001")
    for step in range(30):
        value = 20 + step
        log.positive(
            "bms", "1E10", BASE_MS + step * 10_000, bytes([0x55, *(value * 10 + 500).to_bytes(2)])
        )
        log.positive("bms", "1E11", BASE_MS + step * 10_000 + 50, bytes([step % 3, 9]))
    for step in range(0, 28, 2):
        log.reading("battery_temp", 20 + step + 0.5, BASE_MS + step * 10_000 + 5_100)
    log.reading("battery_temp", 0, BASE_MS - 60_000)
    return load_session(log.write(tmp_path))


def test_fit_candidates_finds_the_interpolated_signal(tmp_path: Path) -> None:
    session = _session(tmp_path)
    readings = select_readings([session], "battery_temp", [])
    candidates = fit_candidates(
        [session], readings, max_gap_ms=30_000, min_n=5, modules=frozenset()
    )
    best = candidates[0]
    assert (best.module, best.did, best.feature, best.offset) == ("bms", "1E10", Feature.U16, 1)
    assert best.n == 14
    assert best.line.slope == pytest.approx(0.1)
    assert best.line.intercept == pytest.approx(-50)
    assert best.line.max_error == pytest.approx(0, abs=1e-9)
    errors = [(c.line.p90_error, c.line.max_error) for c in candidates]
    assert errors == sorted(errors)


def test_fit_candidates_skips_wide_gaps_and_filters_modules(tmp_path: Path) -> None:
    session = _session(tmp_path)
    readings = select_readings([session], "battery_temp", [])
    assert (
        fit_candidates([session], readings, max_gap_ms=5_000, min_n=1, modules=frozenset()) == []
    )
    assert (
        fit_candidates([session], readings, max_gap_ms=30_000, min_n=5, modules=frozenset({"x"}))
        == []
    )


def test_fit_candidates_respects_min_n(tmp_path: Path) -> None:
    session = _session(tmp_path)
    readings = select_readings([session], "battery_temp", [])
    assert (
        fit_candidates([session], readings, max_gap_ms=30_000, min_n=15, modules=frozenset()) == []
    )


def test_select_readings_drops_confirmed_soc_only(tmp_path: Path) -> None:
    log = SessionLog("aaaa0001")
    log.reading("soc", 50, BASE_MS, source="typed")
    log.reading("soc", 51, BASE_MS, source="confirmed")
    log.reading("range", 300, BASE_MS, source="confirmed")
    session = load_session(log.write(tmp_path))
    assert [r.value for r in select_readings([session], "soc", [])] == [50]
    assert [r.value for r in select_readings([session], "range", [])] == [300]


def test_alias_applies_only_to_sessions_before_the_cutoff(tmp_path: Path) -> None:
    old = SessionLog("aaaa0001", created_ms=BASE_MS)
    old.reading("charge_power", 100, BASE_MS)
    new = SessionLog("bbbb0001", created_ms=BASE_MS + 86_400_000)
    new.reading("charge_power", 40, BASE_MS + 86_400_000)
    new.reading("charge_power_max", 90, BASE_MS + 86_400_000)
    sessions = [load_session(old.write(tmp_path)), load_session(new.write(tmp_path))]
    alias = Alias("charge_power", "charge_power_max", BASE_MS + 1)
    assert [r.value for r in select_readings(sessions, "charge_power_max", [alias])] == [100, 90]
    assert [r.value for r in select_readings(sessions, "charge_power", [alias])] == [40]
    everywhere = Alias("charge_power", "charge_power_max", None)
    assert [r.value for r in select_readings(sessions, "charge_power", [everywhere])] == []
