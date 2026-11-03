"""A DID's payloads over time and their decoding."""

import re
from collections.abc import Iterable
from dataclasses import dataclass
from typing import Final

from didscout_logs.sessions import Session

_SPEC: Final = re.compile(
    r"(?P<sign>[us])(?P<bits>8|16|24|32)@(?P<offset>\d+)"
    r"(?:\*(?P<scale>-?(?:\d+\.?\d*|\.\d+)))?"
    r"(?P<add>[+-](?:\d+\.?\d*|\.\d+))?"
)


@dataclass(frozen=True, slots=True)
class DecodeSpec:
    """How to turn payload bytes into a number: `raw * scale + add`.

    Attributes:
        offset: The first byte's index in the payload.
        width: The number of bytes, read big-endian.
        signed: Whether the bytes are two's complement.
        scale: The factor applied to the raw integer.
        add: The offset added after scaling.
    """

    offset: int
    width: int
    signed: bool
    scale: float
    add: float

    def decode(self, payload: bytes) -> float | None:
        """Decode a payload.

        Args:
            payload: The positive response payload.

        Returns:
            The value, or None if the payload is too short.
        """
        end = self.offset + self.width
        if end > len(payload):
            return None
        raw = int.from_bytes(payload[self.offset : end], "big", signed=self.signed)
        return raw * self.scale + self.add


@dataclass(frozen=True, slots=True)
class SeriesPoint:
    """One positive payload of a DID.

    Attributes:
        session_id: The session it was read in.
        at_ms: When the reply arrived, in Unix milliseconds.
        payload: The positive response payload.
    """

    session_id: str
    at_ms: float
    payload: bytes


def parse_decode_spec(text: str) -> DecodeSpec:
    """Parse a decode spec such as `u16@0*0.125-40`.

    The form is `<u|s><bits>@<offset>[*<scale>][<+|-><add>]` with bits
    8, 16, 24 or 32 and the offset in bytes.

    Args:
        text: The spec.

    Returns:
        The parsed spec.

    Raises:
        ValueError: If the text does not have that form.
    """
    match = _SPEC.fullmatch(text)
    if match is None:
        raise ValueError(f"not a decode spec: {text!r} (expected e.g. u16@0*0.125-40)")
    return DecodeSpec(
        offset=int(match["offset"]),
        width=int(match["bits"]) // 8,
        signed=match["sign"] == "s",
        scale=float(match["scale"] or 1),
        add=float(match["add"] or 0),
    )


def did_series(
    sessions: Iterable[Session], module: str, did: str, *, changes_only: bool
) -> list[SeriesPoint]:
    """Collect a DID's positive payloads over time.

    Args:
        sessions: The sessions to search.
        module: The module id.
        did: The DID, any case.
        changes_only: Keep only payloads that differ from the one
            before them in time in the same session.

    Returns:
        The payloads in time order.
    """
    points = sorted(
        (
            SeriesPoint(session.id, read.received_ms, read.payload)
            for session in sessions
            for read in session.reads
            if read.payload is not None
            and read.received_ms is not None
            and read.module == module
            and read.did == did.upper()
        ),
        key=lambda point: point.at_ms,
    )
    if not changes_only:
        return points
    previous: dict[str, bytes] = {}
    changes: list[SeriesPoint] = []
    for point in points:
        if previous.get(point.session_id) != point.payload:
            changes.append(point)
        previous[point.session_id] = point.payload
    return changes
