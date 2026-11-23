"""Decoding of the stored fault codes the app reads with UDS 0x19."""

from collections.abc import Iterable
from dataclasses import dataclass
from typing import Final

from didscout_logs.sessions import Read, Session
from didscout_logs.uds import Positive, outcome_label

_READ_DTC_INFORMATION: Final = 0x19
_REPORT_DTC_BY_STATUS_MASK: Final = 0x02
_DTC_LENGTH: Final = 3
_RECORD_LENGTH: Final = _DTC_LENGTH + 1
_LETTERS: Final = "PCBU"
_STATUS_FLAGS: Final = (
    (0x01, "testFailed"),
    (0x02, "failedThisCycle"),
    (0x04, "pending"),
    (0x08, "confirmed"),
    (0x10, "notCompletedSinceClear"),
    (0x20, "failedSinceClear"),
    (0x40, "notCompletedThisCycle"),
    (0x80, "warningLight"),
)
_TEST_PREFIX: Final = "testplanDtc-"


@dataclass(frozen=True, slots=True)
class Dtc:
    """One stored fault code.

    Attributes:
        code: The SAE-style code (`P0A1B`) of the first two bytes, a
            dash and the failure type byte, e.g. `P0A1B-62`.
        status: The status byte's set flags, most significant first.
    """

    code: str
    status: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class FaultMemory:
    """One ECU's answer to a fault memory read.

    Attributes:
        session: The session id.
        module: The ECU, without the testplan prefix.
        at_ms: When the request was sent, in Unix milliseconds.
        outcome: `positive` or the failure's label.
        availability_mask: The status bits the ECU supports; None
            without a positive reply.
        dtcs: The stored fault codes; empty for an empty memory.
    """

    session: str
    module: str
    at_ms: int
    outcome: str
    availability_mask: int | None
    dtcs: tuple[Dtc, ...]


def decode_dtc(record: bytes) -> Dtc:
    """Decode one 4-byte DTC-and-status record.

    Args:
        record: Three DTC bytes followed by the status byte.

    Returns:
        The decoded fault code.
    """
    high, low, failure_type, status = record
    letter = _LETTERS[high >> 6]
    code = f"{letter}{(high >> 4) & 0x3:X}{high & 0xF:X}{low:02X}-{failure_type:02X}"
    flags = tuple(name for bit, name in reversed(_STATUS_FLAGS) if status & bit)
    return Dtc(code, flags)


def decode_report(payload: bytes) -> tuple[int, tuple[Dtc, ...]] | None:
    """Decode a reportDTCByStatusMask payload.

    Args:
        payload: The bytes after the response's sub-function byte: the
            availability mask, then 4-byte records.

    Returns:
        The availability mask and the fault codes; None if the payload
        is empty or its records are cut off.
    """
    if not payload or (len(payload) - 1) % _RECORD_LENGTH:
        return None
    records = payload[1:]
    return payload[0], tuple(
        decode_dtc(records[i : i + _RECORD_LENGTH]) for i in range(0, len(records), _RECORD_LENGTH)
    )


def fault_memories(sessions: Iterable[Session]) -> list[FaultMemory]:
    """Collect every fault memory read of the sessions.

    Args:
        sessions: The sessions to search.

    Returns:
        One entry per read of `19 02`, in session and file order.
    """
    return [
        _to_memory(session.id, read)
        for session in sessions
        for read in session.reads
        if _is_fault_memory_read(read)
    ]


def _is_fault_memory_read(read: Read) -> bool:
    return (
        len(read.request) >= 2
        and read.request[0] == _READ_DTC_INFORMATION
        and read.request[1] == _REPORT_DTC_BY_STATUS_MASK
    )


def _to_memory(session: str, read: Read) -> FaultMemory:
    module = read.module.removeprefix(_TEST_PREFIX)
    if isinstance(read.outcome, Positive):
        decoded = decode_report(read.outcome.payload)
        if decoded is not None:
            return FaultMemory(session, module, read.started_ms, "positive", *decoded)
        return FaultMemory(session, module, read.started_ms, "malformed", None, ())
    return FaultMemory(session, module, read.started_ms, outcome_label(read.outcome), None, ())
