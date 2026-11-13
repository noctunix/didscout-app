"""Finding DIDs that carry the vehicle position without a reference.

A position candidate is scored by how well the distance between
consecutive decoded positions matches the distance integrated from the
vehicle speed over the same interval. Decoded coordinates never leave
this module: results carry only offsets, scales and distance errors.
"""

import math
import statistics
from bisect import bisect_left, bisect_right
from collections import Counter
from collections.abc import Sequence
from dataclasses import dataclass
from itertools import accumulate
from typing import Final, Literal

from didscout_logs.sessions import Session

SPEED_MODULE: Final = "module7"
SPEED_DID: Final = "F40D"
EXCLUDED_DIDS: Final = frozenset({"F190", "F802", "F18C"})

_MAX_SPEED_GAP_MS: Final = 60_000
_STATIONARY_KM: Final = 0.05
_KM_PER_KMH_MS: Final = 1 / 3_600_000
_EARTH_RADIUS_KM: Final = 6371.0088
_P90: Final = 0.9
_LAT_LIMIT: Final = 90
_LON_LIMIT: Final = 180
_COORD_BYTES: Final = 4
_PAIR_DISTANCES: Final = (-8, -4, 4, 8)

type Order = Literal["big", "little"]
ORDERS: Final[tuple[Order, ...]] = ("big", "little")


@dataclass(frozen=True, slots=True)
class Scale:
    """A conversion from a raw 32-bit integer to degrees.

    Attributes:
        label: The scale as shown in the output.
        factor: Degrees per raw unit.
    """

    label: str
    factor: float


SCALES: Final = (
    Scale("1e-5", 1e-5),
    Scale("1e-6", 1e-6),
    Scale("1e-7", 1e-7),
    Scale("1/3600000", 1 / 3_600_000),
    Scale("180/2^31", 180 / 2**31),
)


@dataclass(frozen=True, slots=True)
class GpsCandidate:
    """A latitude/longitude layout and how well it tracks driving.

    Attributes:
        module: The module id.
        did: The DID.
        lat_offset: Payload offset of the latitude.
        lon_offset: Payload offset of the longitude.
        order: Byte order of both values.
        scale: The conversion to degrees.
        steps: Usable consecutive-sample steps over all sessions.
        ratio: Summed straight-line distance over summed driven
            distance.
        median_error_km: Median absolute difference between
            straight-line and driven distance per step.
        p90_error_km: The same at the 90th percentile (nearest rank).
    """

    module: str
    did: str
    lat_offset: int
    lon_offset: int
    order: Order
    scale: Scale
    steps: int
    ratio: float
    median_error_km: float
    p90_error_km: float


@dataclass(frozen=True, slots=True)
class _Step:
    session_index: int
    first: int
    second: int
    driven_km: float


class _Odometer:
    """Driven distance between two moments of one session."""

    def __init__(self, samples: Sequence[tuple[float, float]]) -> None:
        self._times = [at_ms for at_ms, _ in samples]
        self._speeds = [kmh for _, kmh in samples]
        spans = [
            later - earlier for earlier, later in zip(self._times, self._times[1:], strict=False)
        ]
        legs = [
            0.0 if span > _MAX_SPEED_GAP_MS else (v1 + v2) / 2 * span * _KM_PER_KMH_MS
            for span, v1, v2 in zip(spans, self._speeds, self._speeds[1:], strict=False)
        ]
        self._cumulative = [0.0, *accumulate(legs)]
        self._gaps = [0, *accumulate(int(span > _MAX_SPEED_GAP_MS) for span in spans)]

    def _locate(self, at_ms: float, *, interval_end: bool) -> tuple[int, float] | None:
        if len(self._times) < 2 or not self._times[0] <= at_ms <= self._times[-1]:
            return None
        # End on a sample: leg before it; start: leg after it.
        leg = (
            bisect_left(self._times, at_ms) if interval_end else bisect_right(self._times, at_ms)
        ) - 1
        leg = min(max(leg, 0), len(self._times) - 2)
        span = self._times[leg + 1] - self._times[leg]
        elapsed = at_ms - self._times[leg]
        speed = self._speeds[leg]
        if span:
            speed += (self._speeds[leg + 1] - speed) * elapsed / span
        partial = (self._speeds[leg] + speed) / 2 * elapsed * _KM_PER_KMH_MS
        return leg, self._cumulative[leg] + partial

    def distance(self, start_ms: float, end_ms: float) -> float | None:
        """Integrate the speed between two moments.

        Args:
            start_ms: The interval start in Unix milliseconds.
            end_ms: The interval end, not before the start.

        Returns:
            The distance in kilometres, or None if the interval is not
            fully covered by speed samples or touches a gap between
            them.
        """
        start = self._locate(start_ms, interval_end=False)
        end = self._locate(end_ms, interval_end=True)
        if start is None or end is None or self._gaps[end[0] + 1] != self._gaps[start[0]]:
            return None
        return end[1] - start[1]


def find_gps_candidates(sessions: Sequence[Session], *, min_steps: int = 10) -> list[GpsCandidate]:
    """Rank DIDs and byte layouts that could carry the vehicle position.

    Args:
        sessions: The sessions to analyse.
        min_steps: The fewest usable steps a candidate needs over all
            sessions.

    Returns:
        The candidates sorted by 90th-percentile error, then median
        error. Pairs that are constant, leave the coordinate range,
        move while the vehicle stands, or have too few steps are left
        out.
    """
    odometers = [_Odometer(_speed_samples(session)) for session in sessions]
    series: dict[tuple[str, str], list[tuple[int, float, bytes]]] = {}
    for index, session in enumerate(sessions):
        for read in session.reads:
            if (
                read.payload is None
                or read.received_ms is None
                or read.did in EXCLUDED_DIDS
                or len(read.payload) < 2 * _COORD_BYTES
            ):
                continue
            series.setdefault((read.module, read.did), []).append(
                (index, read.received_ms, read.payload)
            )
    candidates: list[GpsCandidate] = []
    for (module, did), samples in series.items():
        samples.sort(key=lambda sample: (sample[0], sample[1]))
        candidates.extend(_score_did(module, did, samples, odometers, min_steps))
    return sorted(candidates, key=lambda c: (c.p90_error_km, c.median_error_km))


def _speed_samples(session: Session) -> list[tuple[float, float]]:
    return sorted(
        (read.received_ms, float(read.payload[0]))
        for read in session.reads
        if read.module == SPEED_MODULE
        and read.did == SPEED_DID
        and read.payload
        and read.received_ms is not None
    )


def _score_did(
    module: str,
    did: str,
    samples: list[tuple[int, float, bytes]],
    odometers: Sequence[_Odometer],
    min_steps: int,
) -> list[GpsCandidate]:
    length = Counter(len(payload) for _, _, payload in samples).most_common(1)[0][0]
    samples = [sample for sample in samples if len(sample[2]) == length]
    steps = _usable_steps(samples, odometers)
    if len(steps) < min_steps or not any(step.driven_km > _STATIONARY_KM for step in steps):
        return []
    found: list[GpsCandidate] = []
    for order in ORDERS:
        raw = {
            offset: [
                int.from_bytes(payload[offset : offset + _COORD_BYTES], order, signed=True)
                for _, _, payload in samples
            ]
            for offset in range(length - _COORD_BYTES + 1)
        }
        for scale in SCALES:
            lats = {o for o, values in raw.items() if _fits(values, scale, _LAT_LIMIT)}
            lons = {o for o, values in raw.items() if _fits(values, scale, _LON_LIMIT)}
            for lat in sorted(lats):
                for lon in (lat + d for d in _PAIR_DISTANCES if lat + d in lons):
                    candidate = _score_pair(
                        (module, did, lat, lon, order, scale), raw[lat], raw[lon], steps
                    )
                    if candidate is not None:
                        found.append(candidate)
    return found


def _fits(values: Sequence[int], scale: Scale, limit: int) -> bool:
    return (
        min(values) != max(values)
        and max(abs(min(values)), abs(max(values))) * (scale.factor) <= limit
    )


def _usable_steps(
    samples: Sequence[tuple[int, float, bytes]], odometers: Sequence[_Odometer]
) -> list[_Step]:
    steps: list[_Step] = []
    for index in range(1, len(samples)):
        (session, start, _), (later_session, end, _) = samples[index - 1], samples[index]
        if session != later_session:
            continue
        driven = odometers[session].distance(start, end)
        if driven is not None:
            steps.append(_Step(session, index - 1, index, driven))
    return steps


def _score_pair(
    layout: tuple[str, str, int, int, Order, Scale],
    lat_raw: Sequence[int],
    lon_raw: Sequence[int],
    steps: Sequence[_Step],
) -> GpsCandidate | None:
    module, did, lat_offset, lon_offset, order, scale = layout
    errors: list[float] = []
    straight_total = 0.0
    driven_total = 0.0
    for step in steps:
        straight = _haversine_km(
            lat_raw[step.first] * scale.factor,
            lon_raw[step.first] * scale.factor,
            lat_raw[step.second] * scale.factor,
            lon_raw[step.second] * scale.factor,
        )
        if step.driven_km < _STATIONARY_KM and straight >= _STATIONARY_KM:
            return None
        errors.append(abs(straight - step.driven_km))
        straight_total += straight
        driven_total += step.driven_km
    if driven_total <= 0:
        return None
    errors.sort()
    return GpsCandidate(
        module=module,
        did=did,
        lat_offset=lat_offset,
        lon_offset=lon_offset,
        order=order,
        scale=scale,
        steps=len(steps),
        ratio=straight_total / driven_total,
        median_error_km=statistics.median(errors),
        p90_error_km=errors[math.ceil(_P90 * len(errors)) - 1],
    )


def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    a = (
        math.sin((phi2 - phi1) / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(math.radians(lon2 - lon1) / 2) ** 2
    )
    return 2 * _EARTH_RADIUS_KM * math.asin(math.sqrt(a))
