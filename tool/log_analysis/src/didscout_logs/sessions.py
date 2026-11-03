"""Loading recording sessions from a logs directory."""

import json
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Final

from pydantic import TypeAdapter

from didscout_logs.isotp import reassemble
from didscout_logs.records import (
    MARKER_TYPES,
    BufferHeader,
    ExperimentMarker,
    Marker,
    ModulesMarker,
    ReadingMarker,
    ReadRecord,
)
from didscout_logs.uds import Outcome, Positive, decode_reply

BUFFER_SUFFIX: Final = ".jsonl"
MARKERS_SUFFIX: Final = ".markers.jsonl"
TRANSPORT_OK: Final = "ok"
TRANSPORT_WRITE_FAILED: Final = "writeFailed"

_MARKER_ADAPTER: Final[TypeAdapter[Marker]] = TypeAdapter(Marker)


class LogError(Exception):
    """A logs directory, session selection or log file is unusable."""


@dataclass(frozen=True, slots=True)
class Read:
    """One read of a session.

    Attributes:
        session_id: The session the read belongs to.
        sequence: The read's position in the session.
        module: The module id the request went to.
        request: The request bytes, service id first.
        started_ms: When the request was sent, in Unix milliseconds.
        received_ms: When the reply arrived; None on failures.
        duration_ns: How long the exchange took.
        transport: `ok` or the transport failure.
        one_shot: Whether this was a discovery, focus or experiment
            read.
        reply_text: The adapter's reply as ASCII text.
        outcome: What the reply answered.
    """

    session_id: str
    sequence: int
    module: str
    request: bytes
    started_ms: int
    received_ms: int | None
    duration_ns: int
    transport: str
    one_shot: bool
    reply_text: str
    outcome: Outcome

    @property
    def did(self) -> str:
        """The request after the service id as upper-case hex.

        For ReadDataByIdentifier this is the DID.
        """
        return self.request[1:].hex().upper()

    @property
    def end_ms(self) -> float:
        """When the exchange ended, in Unix milliseconds."""
        if self.received_ms is not None:
            return self.received_ms
        return self.started_ms + self.duration_ns / 1e6

    @property
    def payload(self) -> bytes | None:
        """The positive response payload, or None."""
        return self.outcome.payload if isinstance(self.outcome, Positive) else None


@dataclass(frozen=True, slots=True)
class Reading:
    """A value the owner read off the vehicle's display.

    Attributes:
        session_id: The session the reading belongs to.
        quantity: What was read, e.g. `soc`.
        value: The value entered.
        at_ms: When the owner looked at the display, in Unix
            milliseconds.
        source: How the value was entered.
    """

    session_id: str
    quantity: str
    value: float
    at_ms: float
    source: str


@dataclass(frozen=True, slots=True)
class ExperimentStep:
    """One step of a guided experiment run.

    Attributes:
        experiment_id: The experiment's catalog id.
        step: The step name, e.g. `before`.
        at_ms: When the step began, in Unix milliseconds.
        reason: Why the run failed, if the app recorded it.
    """

    experiment_id: str
    step: str
    at_ms: float
    reason: str | None


@dataclass(frozen=True, slots=True)
class Session:
    """One recording session with its markers.

    Attributes:
        id: The session id.
        created_ms: When the session started, in Unix milliseconds.
        reads: Every read, in file order.
        readings: Every reading marker, in file order.
        experiment_steps: Every experiment marker, in file order.
        request_headers: Module id to request header, from the plan
            and modules markers.
    """

    id: str
    created_ms: int
    reads: tuple[Read, ...]
    readings: tuple[Reading, ...]
    experiment_steps: tuple[ExperimentStep, ...]
    request_headers: dict[str, str]


def timestamp_ms(moment: datetime) -> float:
    """Convert an aware datetime to Unix milliseconds.

    Args:
        moment: A timezone-aware datetime.

    Returns:
        The milliseconds since the Unix epoch.
    """
    return moment.timestamp() * 1000


def find_buffers(logs_dir: Path, prefixes: Sequence[str]) -> list[Path]:
    """Select buffer files by session id prefix.

    Args:
        logs_dir: The directory holding buffer and marker files.
        prefixes: Session id prefixes; empty selects every buffer.

    Returns:
        The selected buffer files, sorted by name.

    Raises:
        LogError: If the directory does not exist or a prefix matches
            no buffer.
    """
    if not logs_dir.is_dir():
        raise LogError(f"logs directory not found: {logs_dir}")
    buffers = sorted(
        path
        for path in logs_dir.iterdir()
        if path.name.endswith(BUFFER_SUFFIX) and not path.name.endswith(MARKERS_SUFFIX)
    )
    if not prefixes:
        return buffers
    selected: list[Path] = []
    for prefix in prefixes:
        matches = [path for path in buffers if path.name.startswith(prefix)]
        if not matches:
            raise LogError(f"no session matches {prefix!r} in {logs_dir}")
        selected.extend(path for path in matches if path not in selected)
    return sorted(selected)


def load_sessions(logs_dir: Path, prefixes: Sequence[str]) -> list[Session]:
    """Load the sessions selected by id prefix, oldest first.

    Args:
        logs_dir: The directory holding buffer and marker files.
        prefixes: Session id prefixes; empty selects every session.

    Returns:
        The sessions, sorted by creation time.

    Raises:
        LogError: If the selection or a file is unusable.
    """
    sessions = [load_session(path) for path in find_buffers(logs_dir, prefixes)]
    return sorted(sessions, key=lambda session: session.created_ms)


def session_created_ms(logs_dir: Path, prefix: str) -> int:
    """Look up when the one session matching a prefix started.

    Args:
        logs_dir: The directory holding buffer files.
        prefix: A session id prefix.

    Returns:
        The session's creation time in Unix milliseconds.

    Raises:
        LogError: If the prefix matches no session or several, or the
            buffer header does not parse.
    """
    buffers = find_buffers(logs_dir, [prefix])
    if len(buffers) > 1:
        raise LogError(f"{prefix!r} matches {len(buffers)} sessions in {logs_dir}")
    with buffers[0].open(encoding="utf-8") as lines:
        return _parse_header(buffers[0], next(lines, "")).created_utc_ms


def load_session(buffer: Path) -> Session:
    """Load one buffer file and its marker sidecar, if present.

    Args:
        buffer: The buffer file.

    Returns:
        The parsed session.

    Raises:
        LogError: If a line of either file does not parse.
    """
    with buffer.open(encoding="utf-8") as lines:
        header = _parse_header(buffer, next(lines, ""))
        reads: list[Read] = []
        for number, line in enumerate(lines, start=2):
            try:
                read = _to_read(header.session_id, line)
            except ValueError as err:
                raise _line_error(buffer, number, err) from err
            if read is not None:
                reads.append(read)
    markers = _load_markers(buffer.with_name(buffer.name + MARKERS_SUFFIX))
    return Session(
        id=header.session_id,
        created_ms=header.created_utc_ms,
        reads=tuple(reads),
        readings=tuple(
            Reading(
                header.session_id,
                marker.quantity,
                marker.value,
                timestamp_ms(marker.read_at),
                marker.source,
            )
            for marker in markers
            if isinstance(marker, ReadingMarker)
        ),
        experiment_steps=tuple(
            ExperimentStep(marker.id, marker.step, timestamp_ms(marker.at), marker.reason)
            for marker in markers
            if isinstance(marker, ExperimentMarker)
        ),
        request_headers={
            module.id: module.request
            for marker in markers
            if isinstance(marker, ModulesMarker)
            for module in marker.modules
        },
    )


def _parse_header(buffer: Path, line: str) -> BufferHeader:
    try:
        return BufferHeader.model_validate_json(line)
    except ValueError as err:
        raise _line_error(buffer, 1, err) from err


def _to_read(session_id: str, line: str) -> Read | None:
    fields = json.loads(line)
    if "gap" in fields:
        return None
    record = ReadRecord.model_validate(fields)
    module, separator, command = record.signal_id.partition("_")
    if not separator:
        raise ValueError(f"signal id without a module: {record.signal_id!r}")
    request = bytes.fromhex(command)
    reply_text = bytes.fromhex(record.raw).decode("ascii")
    return Read(
        session_id=session_id,
        sequence=record.sequence,
        module=module,
        request=request,
        started_ms=record.request_started_utc_ms,
        received_ms=record.received_utc_ms,
        duration_ns=record.duration_ns,
        transport=record.transport,
        one_shot=record.one_shot,
        reply_text=reply_text,
        outcome=decode_reply(request, reassemble(reply_text)),
    )


def _load_markers(path: Path) -> list[Marker]:
    if not path.exists():
        return []
    markers: list[Marker] = []
    with path.open(encoding="utf-8") as lines:
        for number, line in enumerate(lines, start=1):
            try:
                fields = json.loads(line)
                if fields.get("type") in MARKER_TYPES:
                    markers.append(_MARKER_ADAPTER.validate_python(fields))
            except ValueError as err:
                raise _line_error(path, number, err) from err
    return markers


def _line_error(path: Path, number: int, err: ValueError) -> LogError:
    return LogError(f"{path}:{number}: {err}")
