"""Fitting display readings against DID payload bytes."""

import math
from bisect import bisect_left
from collections import defaultdict
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from enum import StrEnum
from typing import Final

from didscout_logs.sessions import Reading, Session

SOC: Final = "soc"
SOURCE_CONFIRMED: Final = "confirmed"
_P90: Final = 0.9


class Feature(StrEnum):
    """How a candidate value is read from a payload, big-endian."""

    U8 = "u8"
    U16 = "u16"
    S16 = "s16"

    @property
    def width(self) -> int:
        """The number of payload bytes the feature reads."""
        return 1 if self is Feature.U8 else 2

    def read(self, payload: bytes, offset: int) -> int:
        """Read the feature at an offset.

        Args:
            payload: The positive response payload.
            offset: The first byte's index; `offset + width` must not
                exceed the payload length.

        Returns:
            The integer value.
        """
        return int.from_bytes(
            payload[offset : offset + self.width], "big", signed=self is Feature.S16
        )


@dataclass(frozen=True, slots=True)
class Alias:
    """A quantity name that older sessions recorded under another name.

    Attributes:
        recorded: The name the readings carry.
        meant: The quantity they stand for.
        before_ms: Only sessions created before this Unix millisecond
            are affected; None affects every session.
    """

    recorded: str
    meant: str
    before_ms: float | None


@dataclass(frozen=True, slots=True)
class LineFit:
    """A least-squares line `value = slope * x + intercept`.

    Attributes:
        slope: The fitted slope.
        intercept: The fitted intercept.
        r: Pearson's correlation coefficient of x and value.
        p90_error: The 90th-percentile absolute residual (nearest
            rank).
        max_error: The largest absolute residual.
    """

    slope: float
    intercept: float
    r: float
    p90_error: float
    max_error: float


@dataclass(frozen=True, slots=True)
class Candidate:
    """A payload feature fitted against readings.

    Attributes:
        module: The module id.
        did: The DID.
        feature: How the value is read.
        offset: Where in the payload it is read.
        n: The number of readings used.
        line: The fit.
    """

    module: str
    did: str
    feature: Feature
    offset: int
    n: int
    line: LineFit


@dataclass(frozen=True, slots=True)
class _Sample:
    at_ms: float
    payload: bytes


@dataclass(frozen=True, slots=True)
class _Match:
    before: _Sample
    after: _Sample
    weight: float
    value: float


def select_readings(
    sessions: Iterable[Session], quantity: str, aliases: Sequence[Alias]
) -> list[Reading]:
    """Collect the readings of a quantity, applying aliases.

    A reading recorded under an alias's `recorded` name counts as its
    `meant` quantity in the sessions the alias covers, and no longer as
    the recorded one there. SoC readings the owner only confirmed are
    left out: they echo the app's own estimate.

    Args:
        sessions: The sessions to search.
        quantity: The quantity to collect, e.g. `soc`.
        aliases: Renames to apply first.

    Returns:
        The matching readings.
    """
    selected: list[Reading] = []
    for session in sessions:
        renames = {
            alias.recorded: alias.meant
            for alias in aliases
            if alias.before_ms is None or session.created_ms < alias.before_ms
        }
        selected.extend(
            reading
            for reading in session.readings
            if renames.get(reading.quantity, reading.quantity) == quantity
            and not (quantity == SOC and reading.source == SOURCE_CONFIRMED)
        )
    return selected


def fit_line(xs: Sequence[float], ys: Sequence[float]) -> LineFit | None:
    """Fit `y = slope * x + intercept` by ordinary least squares.

    Args:
        xs: The feature values.
        ys: The readings, same length as `xs`.

    Returns:
        The fit, or None when fewer than two points are given or the x
        values do not vary.
    """
    n = len(xs)
    if n < 2:
        return None
    mean_x = sum(xs) / n
    mean_y = sum(ys) / n
    sxx = sum((x - mean_x) ** 2 for x in xs)
    if sxx == 0:
        return None
    sxy = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys, strict=True))
    syy = sum((y - mean_y) ** 2 for y in ys)
    slope = sxy / sxx
    intercept = mean_y - slope * mean_x
    errors = sorted(abs(y - (slope * x + intercept)) for x, y in zip(xs, ys, strict=True))
    return LineFit(
        slope=slope,
        intercept=intercept,
        r=sxy / math.sqrt(sxx * syy) if syy else math.nan,
        p90_error=errors[math.ceil(_P90 * n) - 1],
        max_error=errors[-1],
    )


def fit_candidates(
    sessions: Iterable[Session],
    readings: Sequence[Reading],
    *,
    max_gap_ms: float,
    min_n: int,
    modules: frozenset[str],
) -> list[Candidate]:
    """Fit every payload feature of every DID against the readings.

    Each reading is matched with the two positive samples of a DID in
    its session that bracket it in time (by reply time), and the
    feature is linearly interpolated between them. A reading is
    skipped for a DID when no sample precedes or follows it, or the
    bracketing samples lie more than `max_gap_ms` apart.

    Args:
        sessions: The sessions holding the samples.
        readings: The readings to fit against.
        max_gap_ms: The largest allowed distance between the
            bracketing samples.
        min_n: The fewest readings a candidate needs.
        modules: Only these module ids; empty means every module.

    Returns:
        The candidates, best first: by 90th-percentile error, then by
        maximum error.
    """
    by_session: dict[str, list[Reading]] = defaultdict(list)
    for reading in readings:
        by_session[reading.session_id].append(reading)
    matches: dict[tuple[str, str], list[_Match]] = defaultdict(list)
    for session in sessions:
        session_readings = by_session.get(session.id)
        if not session_readings:
            continue
        for key, samples in _samples_by_did(session, modules).items():
            for reading in session_readings:
                match = _bracket(samples, reading, max_gap_ms)
                if match is not None:
                    matches[key].append(match)
    candidates = [
        candidate
        for (module, did), did_matches in matches.items()
        if len(did_matches) >= min_n
        for candidate in _fit_did(module, did, did_matches, min_n)
    ]
    return sorted(candidates, key=lambda c: (c.line.p90_error, c.line.max_error))


def _samples_by_did(
    session: Session, modules: frozenset[str]
) -> Mapping[tuple[str, str], list[_Sample]]:
    samples: dict[tuple[str, str], list[_Sample]] = defaultdict(list)
    for read in session.reads:
        if (
            read.payload is not None
            and read.received_ms is not None
            and (not modules or read.module in modules)
        ):
            samples[(read.module, read.did)].append(_Sample(read.received_ms, read.payload))
    for did_samples in samples.values():
        did_samples.sort(key=lambda sample: sample.at_ms)
    return samples


def _bracket(samples: Sequence[_Sample], reading: Reading, max_gap_ms: float) -> _Match | None:
    after = bisect_left(samples, reading.at_ms, key=lambda sample: sample.at_ms)
    if after < len(samples) and samples[after].at_ms == reading.at_ms:
        return _Match(samples[after], samples[after], 0.0, reading.value)
    if after == 0 or after == len(samples):
        return None
    first, second = samples[after - 1], samples[after]
    if second.at_ms - first.at_ms > max_gap_ms:
        return None
    weight = (reading.at_ms - first.at_ms) / (second.at_ms - first.at_ms)
    return _Match(first, second, weight, reading.value)


def _fit_did(
    module: str,
    did: str,
    matches: Sequence[_Match],
    min_n: int,
) -> Iterable[Candidate]:
    width = max(min(len(match.before.payload), len(match.after.payload)) for match in matches)
    for feature in Feature:
        for offset in range(width - feature.width + 1):
            end = offset + feature.width
            xs: list[float] = []
            ys: list[float] = []
            for match in matches:
                if end > len(match.before.payload) or end > len(match.after.payload):
                    continue
                x0 = feature.read(match.before.payload, offset)
                x1 = feature.read(match.after.payload, offset)
                xs.append(x0 + (x1 - x0) * match.weight)
                ys.append(match.value)
            if len(xs) < min_n:
                continue
            line = fit_line(xs, ys)
            if line is not None:
                yield Candidate(module, did, feature, offset, len(xs), line)
