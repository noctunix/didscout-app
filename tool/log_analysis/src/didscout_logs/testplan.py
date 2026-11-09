"""Decoding of the one-shot testplan check's fixed probe catalogue.

The app runs this catalogue once per recording and once per vehicle
phase change: classic OBD mode 01 PIDs sent functionally, the same
PIDs as OBDonUDS DIDs, and a handful of manufacturer-specific
hypotheses. Its reads land in the normal recording buffer under
module ids `testplanMode1`, `testplanUds04`/`06`/`07`,
`testplanGateway` and `testplanTyres`.
"""

from collections import Counter
from collections.abc import Iterable
from dataclasses import dataclass
from typing import Final

from didscout_logs.isotp import reassemble
from didscout_logs.series import DecodeSpec
from didscout_logs.sessions import TRANSPORT_OK, Read, Session
from didscout_logs.uds import outcome_label, positive_replies

_BITMAP_BYTES: Final = 4
_BITS_PER_BYTE: Final = 8


@dataclass(frozen=True, slots=True)
class BitmapProbe:
    """A probe whose positive payload is a J1979 supported-PID bitmap.

    Attributes:
        module: The module id, the signal id's part before `_`.
        header: The request header the app sends to.
        request: The request as the app's catalogue names it, e.g.
            `0100` or `F420`.
        match_did: The DID or PID `Read.did` reports for this probe.
    """

    module: str
    header: str
    request: str
    match_did: str


@dataclass(frozen=True, slots=True)
class ValueProbe:
    """A probe whose positive payload the check does not decode.

    Attributes:
        module: The module id, the signal id's part before `_`.
        header: The request header the app sends to.
        request: The request as the app's catalogue names it.
        match_did: The DID or PID `Read.did` reports for this probe.
    """

    module: str
    header: str
    request: str
    match_did: str


@dataclass(frozen=True, slots=True)
class Field:
    """One value a hypothesis decode extracts from a payload.

    Attributes:
        name: Short label, e.g. `V` or `temp1`.
        spec: Where and how to read the value.
        unit: The physical unit, for display; may be empty.
    """

    name: str
    spec: DecodeSpec
    unit: str


@dataclass(frozen=True, slots=True)
class HypothesisDecode:
    """A manufacturer-hypothesis decode of a probe's payload.

    Attributes:
        fields: The values to extract, in display order.
        verified: Whether the decode has been checked against this
            car, rather than taken on faith from a research dossier
            or another car's public catalogue.
    """

    fields: tuple[Field, ...]
    verified: bool


@dataclass(frozen=True, slots=True)
class HypothesisProbe:
    """A probe decoded from a manufacturer-specific hypothesis.

    Attributes:
        module: The module id, the signal id's part before `_`.
        header: The request header the app sends to.
        request: The request as the app's catalogue names it.
        match_did: The DID or PID `Read.did` reports for this probe.
        decode: The hypothesis decode for its positive payload.
    """

    module: str
    header: str
    request: str
    match_did: str
    decode: HypothesisDecode


type Probe = BitmapProbe | ValueProbe | HypothesisProbe


@dataclass(frozen=True, slots=True)
class SupportedPids:
    """A decoded J1979 supported-PID bitmap.

    Attributes:
        pids: The supported PIDs in the requested range, as
            upper-case hex.
        next_range_supported: Whether the bitmap's last bit, which
            flags the next PID range rather than naming a PID of its
            own, was set.
    """

    pids: tuple[str, ...]
    next_range_supported: bool


@dataclass(frozen=True, slots=True)
class OutcomeCount:
    """How often one outcome label occurred for a probe.

    Attributes:
        label: The outcome label, e.g. `positive` or `timeout`.
        count: The number of reads with this outcome.
    """

    label: str
    count: int


@dataclass(frozen=True, slots=True)
class HeaderReply:
    """One responding header's positive payload to a probe.

    Attributes:
        header: The responder's CAN identifier.
        payload: The positive response payload.
    """

    header: str
    payload: bytes


@dataclass(frozen=True, slots=True)
class ProbeSummary:
    """A probe's outcomes across the selected sessions.

    Attributes:
        probe: The probe.
        sessions: The number of sessions with at least one read of
            this probe.
        outcomes: Outcome label to read count, most frequent first.
        latest: The headers that answered the latest positive read,
            each with its own payload; empty if the probe was never
            answered positively.
    """

    probe: Probe
    sessions: int
    outcomes: tuple[OutcomeCount, ...]
    latest: tuple[HeaderReply, ...]


_MODE1_MODULE: Final = "testplanMode1"
_MODE1_HEADER: Final = "7DF"
_MODE1_BITMAP_PIDS: Final = ("00", "20", "40", "60", "80", "A0", "C0")
_MODE1_VALUE_PIDS: Final = ("5B", "9A", "0D", "46", "42", "A6", "D0", "D2", "D8")

_UDS_MODULES: Final = (
    ("testplanUds04", "18DA04F1"),
    ("testplanUds06", "18DA06F1"),
    ("testplanUds07", "18DA07F1"),
)
_UDS_BITMAP_DIDS: Final = ("F400", "F420", "F440", "F460", "F480", "F4A0", "F4C0")
_UDS_VALUE_DIDS: Final = ("F45B", "F49A", "F4D0", "F4D2", "F4D8")

_GATEWAY_MODULE: Final = "testplanGateway"
_GATEWAY_HEADER: Final = "710"
_TYRES_MODULE: Final = "testplanTyres"
_TYRES_HEADER: Final = "70B"
_TYRE_DIDS: Final = ("18A0", "18A1", "18A2", "18A3")

# Unverified except where noted: taken from a research dossier or
# another car's public catalogue, not yet checked against this car.
_DECODE_2AF7: Final = HypothesisDecode(
    fields=(
        Field("V", DecodeSpec(0, 2, False, 0.001, 4.0), "V"),
        Field("I", DecodeSpec(2, 4, True, 1.0, 0.0), "mA"),
        Field("12V_SoC", DecodeSpec(7, 1, False, 1.0, 0.0), "%"),
        Field("temp1", DecodeSpec(8, 1, False, 1.0, -40.0), "C"),
        Field("temp2", DecodeSpec(9, 1, False, 1.0, -40.0), "C"),
        Field("pct1", DecodeSpec(20, 1, False, 1.0, 0.0), "%"),
        Field("pct2", DecodeSpec(21, 1, False, 1.0, 0.0), "%"),
        Field("Ah", DecodeSpec(22, 1, False, 1.0, 0.0), "Ah"),
    ),
    verified=False,
)
_DECODE_2AB2: Final = HypothesisDecode(
    fields=(Field("value", DecodeSpec(0, 2, False, 50.0, 0.0), ""),),
    verified=False,
)
_DECODE_2AB6: Final = HypothesisDecode(
    fields=(Field("range", DecodeSpec(0, 2, False, 1.0, 0.0), "km"),),
    verified=True,
)
_DECODE_2AB7: Final = HypothesisDecode(
    fields=tuple(Field(f"f{i}", DecodeSpec(i * 2, 2, False, 0.1, 0.0), "") for i in range(7)),
    verified=False,
)
_DECODE_2AB8: Final = HypothesisDecode(
    fields=(Field("energy", DecodeSpec(2, 2, False, 25.0, 0.0), "Wh"),),
    verified=True,
)
_DECODE_TYRE_PRESSURE: Final = HypothesisDecode(
    fields=(Field("pressure", DecodeSpec(5, 1, False, 1 / 40, 0.0), "bar"),),
    verified=False,
)

_GATEWAY_DECODES: Final = (
    ("2AF7", _DECODE_2AF7),
    ("2AB2", _DECODE_2AB2),
    ("2AB6", _DECODE_2AB6),
    ("2AB7", _DECODE_2AB7),
    ("2AB8", _DECODE_2AB8),
)


def _mode1_probes() -> list[Probe]:
    probes: list[Probe] = [
        BitmapProbe(_MODE1_MODULE, _MODE1_HEADER, f"01{pid}", pid) for pid in _MODE1_BITMAP_PIDS
    ]
    probes += [
        ValueProbe(_MODE1_MODULE, _MODE1_HEADER, f"01{pid}", pid) for pid in _MODE1_VALUE_PIDS
    ]
    return probes


def _uds_probes() -> list[Probe]:
    probes: list[Probe] = []
    for module, header in _UDS_MODULES:
        probes += [BitmapProbe(module, header, did, did) for did in _UDS_BITMAP_DIDS]
        probes += [ValueProbe(module, header, did, did) for did in _UDS_VALUE_DIDS]
    return probes


def _hypothesis_probes() -> list[Probe]:
    probes: list[Probe] = [
        HypothesisProbe(_GATEWAY_MODULE, _GATEWAY_HEADER, did, did, decode)
        for did, decode in _GATEWAY_DECODES
    ]
    probes += [
        HypothesisProbe(_TYRES_MODULE, _TYRES_HEADER, did, did, _DECODE_TYRE_PRESSURE)
        for did in _TYRE_DIDS
    ]
    return probes


def testplan_catalogue() -> list[Probe]:
    """The testplan check's fixed probe catalogue.

    Returns:
        Every probe, in the app's run order.
    """
    return [*_mode1_probes(), *_uds_probes(), *_hypothesis_probes()]


def decode_bitmap(payload: bytes, base: int) -> SupportedPids | None:
    """Decode a 4-byte J1979 supported-PID bitmap.

    Bit 7 of the first byte flags PID `base + 1`; each following bit,
    most significant first, flags the next PID. The last bit (bit 0
    of the fourth byte) flags support for the next PID range rather
    than naming a PID of its own.

    Args:
        payload: The positive response payload.
        base: The `x0` the request's PID or DID named, e.g. 0x20 for
            `0120` or `F420`.

    Returns:
        The decoded bitmap, or None if the payload has fewer than 4
        bytes.
    """
    if len(payload) < _BITMAP_BYTES:
        return None
    pids = [
        f"{base + byte_index * _BITS_PER_BYTE + bit + 1:02X}"
        for byte_index, byte in enumerate(payload[:_BITMAP_BYTES])
        for bit in range(_BITS_PER_BYTE)
        if byte & (0x80 >> bit)
        if not (byte_index == _BITMAP_BYTES - 1 and bit == _BITS_PER_BYTE - 1)
    ]
    return SupportedPids(tuple(pids), bool(payload[_BITMAP_BYTES - 1] & 0x01))


def describe_payload(probe: Probe, payload: bytes) -> str:
    """Render a probe's positive payload as hex, with its decode.

    Args:
        probe: The probe the payload answered.
        payload: The positive response payload.

    Returns:
        The hex payload, followed by two spaces and the decode once
        the payload was long enough for one.
    """
    hex_payload = payload.hex(" ").upper()
    decoded = _decode(probe, payload)
    return f"{hex_payload}  {decoded}" if decoded else hex_payload


def _decode(probe: Probe, payload: bytes) -> str:
    match probe:
        case BitmapProbe():
            return _describe_bitmap(payload, int(probe.request[-2:], 16))
        case ValueProbe():
            return ""
        case HypothesisProbe():
            return _describe_hypothesis(probe.decode, payload)


def _describe_bitmap(payload: bytes, base: int) -> str:
    decoded = decode_bitmap(payload, base)
    if decoded is None:
        return ""
    text = "PIDs " + " ".join(decoded.pids) if decoded.pids else "no PIDs supported"
    return f"{text}, next range supported" if decoded.next_range_supported else text


def _describe_hypothesis(decode: HypothesisDecode, payload: bytes) -> str:
    parts = [
        f"{field.name}={value:g}{field.unit}"
        for field in decode.fields
        if (value := field.spec.decode(payload)) is not None
    ]
    if not parts:
        return ""
    label = "verified" if decode.verified else "unverified"
    return f"{label}: {' '.join(parts)}"


def summarize_testplan(sessions: Iterable[Session]) -> list[ProbeSummary]:
    """Summarize every catalogue probe's outcomes across sessions.

    Args:
        sessions: The sessions to search.

    Returns:
        One summary per catalogue probe, in catalogue order; a probe
        never read is included with no outcomes.
    """
    sessions = list(sessions)
    return [_summarize_probe(probe, sessions) for probe in testplan_catalogue()]


def _summarize_probe(probe: Probe, sessions: list[Session]) -> ProbeSummary:
    reads = [
        read
        for session in sessions
        for read in session.reads
        if read.module == probe.module and read.did == probe.match_did
    ]
    tally = Counter(_outcome_label(read) for read in reads)
    positive_reads = [read for read in reads if read.payload is not None]
    latest: tuple[HeaderReply, ...] = ()
    if positive_reads:
        latest_read = max(positive_reads, key=lambda read: read.end_ms)
        latest = _latest_headers(latest_read)
    return ProbeSummary(
        probe=probe,
        sessions=len({read.session_id for read in reads}),
        outcomes=tuple(OutcomeCount(label, count) for label, count in tally.most_common()),
        latest=latest,
    )


def _outcome_label(read: Read) -> str:
    """Label a read's outcome for counting.

    Args:
        read: The read.

    Returns:
        The transport failure, e.g. `timeout` or `cancelled`, if the
        exchange did not complete; otherwise the decoded reply's
        outcome.
    """
    if read.transport != TRANSPORT_OK:
        return read.transport
    return outcome_label(read.outcome)


def _latest_headers(read: Read) -> tuple[HeaderReply, ...]:
    reply = reassemble(read.reply_text)
    return tuple(
        HeaderReply(header, payload) for header, payload in positive_replies(read.request, reply)
    )
