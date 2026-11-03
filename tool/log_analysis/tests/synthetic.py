"""Builders for synthetic buffer and marker files; no real captures."""

import json
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

BASE_MS = 1_700_000_000_000


def iso(at_ms: float) -> str:
    return datetime.fromtimestamp(at_ms / 1000, UTC).isoformat().replace("+00:00", "Z")


def frames(header: str, data: bytes) -> list[str]:
    """Segment one message into padded ISO-TP frame lines, no spaces."""
    if len(data) <= 7:
        frame = bytes([len(data)]) + data
        return [header + frame.hex().upper()]
    lines = [
        header + (bytes([0x10 | (len(data) >> 8), len(data) & 0xFF]) + data[:6]).hex().upper()
    ]
    rest = data[6:]
    sequence = 1
    while rest:
        chunk = rest[:7].ljust(7, b"\xaa")
        lines.append(header + (bytes([0x20 | sequence]) + chunk).hex().upper())
        rest = rest[7:]
        sequence = (sequence + 1) & 0xF
    return lines


def reply(*lines: str) -> str:
    return "\r".join(lines) + "\r\r"


def positive_reply(header: str, did: str, payload: bytes) -> str:
    return reply(*frames(header, bytes([0x62]) + bytes.fromhex(did) + payload))


@dataclass
class SessionLog:
    session_id: str
    created_ms: int = BASE_MS
    lines: list[dict[str, object]] = field(default_factory=list)
    markers: list[dict[str, object]] = field(default_factory=list)
    sequence: int = 0

    def read(
        self,
        module: str,
        did: str,
        at_ms: float,
        reply_text: str,
        *,
        transport: str = "ok",
        duration_ms: float = 100,
        one_shot: bool = False,
    ) -> None:
        self.sequence += 1
        record: dict[str, object] = {
            "sequence": self.sequence,
            "signalId": f"{module}_22{did.lower()}",
            "requestStartedUtcMs": int(at_ms),
            "monotonicStartNs": self.sequence,
            "durationNs": int(duration_ms * 1e6),
            "timebaseId": "synthetic",
            "raw": reply_text.encode("ascii").hex(),
            "transport": transport,
        }
        if transport == "ok":
            record["receivedUtcMs"] = int(at_ms + duration_ms)
        if one_shot:
            record["oneShot"] = True
        self.lines.append(record)

    def positive(
        self, module: str, did: str, at_ms: float, payload: bytes, header: str = "7E8"
    ) -> None:
        self.read(module, did, at_ms, positive_reply(header, did, payload))

    def gap(self) -> None:
        self.lines.append({"gap": 1, "afterSequence": self.sequence, "reason": "synthetic"})

    def reading(self, quantity: str, value: float, at_ms: float, source: str = "typed") -> None:
        self.markers.append(
            {
                "type": "reading",
                "quantity": quantity,
                "value": value,
                "unit": "",
                "read_at": iso(at_ms),
                "saved_at": iso(at_ms + 1000),
                "source": source,
                "prefill": None,
                "live_value": None,
                "speed_kmh": 0,
            }
        )

    def experiment(
        self, experiment_id: str, step: str, at_ms: float, reason: str | None = None
    ) -> None:
        marker: dict[str, object] = {
            "type": "experiment",
            "id": experiment_id,
            "step": step,
            "at": iso(at_ms),
        }
        if reason is not None:
            marker["reason"] = reason
        self.markers.append(marker)

    def write(self, directory: Path) -> Path:
        header = {
            "format": "didscout-buffer",
            "formatVersion": 1,
            "sessionId": self.session_id,
            "planId": "synthetic",
            "planVersion": 1,
            "timebaseId": "synthetic",
            "createdUtcMs": self.created_ms,
        }
        buffer = directory / f"{self.session_id}.jsonl"
        buffer.write_text(
            "".join(json.dumps(line) + "\n" for line in [header, *self.lines]), encoding="utf-8"
        )
        if self.markers:
            (directory / f"{self.session_id}.jsonl.markers.jsonl").write_text(
                "".join(json.dumps(marker) + "\n" for marker in self.markers), encoding="utf-8"
            )
        return buffer
