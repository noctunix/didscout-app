import math
from pathlib import Path

import pytest

from didscout_logs.cli import main
from didscout_logs.gps import GpsCandidate, find_gps_candidates
from didscout_logs.sessions import Session, load_session
from tests.synthetic import BASE_MS, SessionLog

S = 1000
KM_PER_DEGREE = 111.195
STATIONARY_SECONDS = 20
DRIVING_SECONDS = 120
POSITION_EVERY_S = 5
START_LAT = 10.0
START_LON = 20.0


def _speed_kmh(second: int) -> int:
    if second < STATIONARY_SECONDS:
        return 0
    return round(50 + 30 * math.sin(second / 7))


def _coordinate(degrees: float) -> bytes:
    return round(degrees * 1_000_000).to_bytes(4, "big", signed=True)


def _synthetic_session(directory: Path) -> Session:
    log = SessionLog("aaaa0001")
    driven_km = 0.0
    for second in range(STATIONARY_SECONDS + DRIVING_SECONDS):
        at_ms = BASE_MS + second * S
        speed = _speed_kmh(second)
        if second:
            driven_km += (speed + _speed_kmh(second - 1)) / 2 / 3600
        log.positive("module7", "F40D", at_ms, bytes([int(speed)]))
        if second % POSITION_EVERY_S:
            continue
        lat = START_LAT + driven_km * math.sqrt(0.5) / KM_PER_DEGREE
        lon = START_LON + driven_km * math.sqrt(0.5) / (
            KM_PER_DEGREE * math.cos(math.radians(lat))
        )
        log.positive("gnss", "A001", at_ms, _coordinate(lat) + _coordinate(lon) + b"\x01")
        noise = _coordinate((second * 7919) % 160 - 80) + _coordinate(
            (second * 104729) % 340 - 170
        )
        log.positive("noise", "A002", at_ms, noise)
        log.positive("flat", "A003", at_ms, _coordinate(START_LAT) + _coordinate(START_LON))
    return load_session(log.write(directory))


@pytest.fixture
def session(tmp_path: Path) -> Session:
    return _synthetic_session(tmp_path)


def test_true_position_ranks_first_with_small_error(session: Session) -> None:
    candidates = find_gps_candidates([session], min_steps=10)
    best = candidates[0]
    assert (best.module, best.did, best.lat_offset, best.lon_offset) == ("gnss", "A001", 0, 4)
    assert (best.order, best.scale.label) == ("big", "1e-6")
    assert best.steps >= 20
    assert best.p90_error_km < 0.02
    assert 0.9 < best.ratio < 1.01


def test_noise_and_constant_dids_are_filtered(session: Session) -> None:
    candidates = find_gps_candidates([session], min_steps=10)
    assert {c.module for c in candidates} <= {"gnss"}


def test_too_few_steps_yield_nothing(session: Session) -> None:
    assert find_gps_candidates([session], min_steps=1000) == []


def test_excluded_dids_are_never_candidates(tmp_path: Path) -> None:
    log = SessionLog("aaaa0002")
    for second in range(60):
        at_ms = BASE_MS + second * S
        log.positive("module7", "F40D", at_ms, bytes([60]))
        log.positive("gnss", "F190", at_ms, _coordinate(10 + second * 0.0001) * 2)
    session = load_session(log.write(tmp_path))
    assert find_gps_candidates([session], min_steps=1) == []


def test_speed_gap_skips_steps(tmp_path: Path) -> None:
    log = SessionLog("aaaa0003")
    for second in (0, 10, 20, 200, 210, 220):
        at_ms = BASE_MS + second * S
        log.positive("module7", "F40D", at_ms, bytes([36]))
        lat = START_LAT + 0.0001 * second
        log.positive("gnss", "A001", at_ms, _coordinate(lat) + _coordinate(START_LON + lat))
    session = load_session(log.write(tmp_path))
    steps = {c.steps for c in find_gps_candidates([session], min_steps=1)}
    assert steps == {4}


@pytest.mark.usefixtures("session")
def test_cli_prints_ranking_without_coordinates(
    capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    assert main(["gps", "--logs", str(tmp_path), "--top", "3"]) == 0
    out = capsys.readouterr().out
    lines = out.splitlines()
    assert lines[0].split() == [
        "module",
        "DID",
        "lat",
        "offset",
        "lon",
        "offset",
        "order",
        "scale",
        "steps",
        "ratio",
        "median",
        "err",
        "km",
        "p90",
        "err",
        "km",
    ]
    assert lines[1].split()[:6] == ["gnss", "A001", "0", "4", "big", "1e-6"]
    for forbidden in ("10.0", "20.0", "10000000", "20000000", "10.1", "20.1"):
        assert forbidden not in out


def test_candidate_type_carries_no_coordinates() -> None:
    assert not {"lat", "lon", "latitude", "longitude"} & set(GpsCandidate.__slots__)
