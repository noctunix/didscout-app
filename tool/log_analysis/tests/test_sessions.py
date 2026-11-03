import json
from pathlib import Path

import pytest

from didscout_logs.sessions import (
    LogError,
    find_buffers,
    load_session,
    load_sessions,
    session_created_ms,
)
from didscout_logs.uds import NoAnswer, NoAnswerReason, Positive
from tests.synthetic import BASE_MS, SessionLog, iso, reply


def test_load_session_parses_reads_and_skips_gap_lines(tmp_path: Path) -> None:
    log = SessionLog("aaaa0001")
    log.positive("bcm", "1234", BASE_MS + 1000, bytes([7]))
    log.gap()
    log.read("bcm", "1235", BASE_MS + 2000, "", transport="timeout", duration_ms=2000)
    session = load_session(log.write(tmp_path))
    assert session.id == "aaaa0001"
    assert session.created_ms == BASE_MS
    first, second = session.reads
    assert (first.module, first.did, first.request) == ("bcm", "1234", bytes.fromhex("221234"))
    assert first.outcome == Positive(bytes([7]))
    assert first.payload == bytes([7])
    assert first.received_ms == BASE_MS + 1100
    assert second.received_ms is None
    assert second.end_ms == BASE_MS + 4000
    assert second.outcome == NoAnswer(NoAnswerReason.EMPTY)
    assert second.payload is None


def test_module_ids_may_contain_dashes(tmp_path: Path) -> None:
    log = SessionLog("aaaa0001")
    log.read("vag29-7B", "1E10", BASE_MS, reply("18DAF1100462ABCD07"))
    read = load_session(log.write(tmp_path)).reads[0]
    assert (read.module, read.did) == ("vag29-7B", "1E10")


def test_markers_are_parsed_and_unknown_ones_tolerated(tmp_path: Path) -> None:
    log = SessionLog("aaaa0001")
    log.reading("soc", 55, BASE_MS + 5000, source="stepped")
    log.experiment("door", "before", BASE_MS + 6000)
    log.experiment("door", "rewind", BASE_MS + 6500)
    log.experiment("door", "cancelled", BASE_MS + 7000, reason="noAnswer")
    log.markers.extend(
        [
            {"timestamp": iso(BASE_MS), "kind": "note", "text": "legacy"},
            {"timestamp": iso(BASE_MS), "kind": "phase", "phase": "drive"},
            {"type": "phase", "phase": "park", "at": iso(BASE_MS)},
            {"type": "note", "text": "x", "at": iso(BASE_MS)},
            {"type": "event", "label": "x", "at": iso(BASE_MS)},
            {"type": "future", "anything": 1},
            {
                "type": "plan",
                "planId": "p",
                "planVersion": 1,
                "at": iso(BASE_MS),
                "modules": [{"id": "bcm", "request": "70E", "response": "778", "protocol": "6"}],
            },
            {
                "type": "modules",
                "at": iso(BASE_MS),
                "modules": [
                    {"id": "bms", "request": "17FC0010", "response": "17FE0010", "protocol": "7"}
                ],
            },
        ]
    )
    session = load_session(log.write(tmp_path))
    (reading,) = session.readings
    assert (reading.quantity, reading.value, reading.source) == ("soc", 55, "stepped")
    assert reading.at_ms == pytest.approx(BASE_MS + 5000)
    assert [step.step for step in session.experiment_steps] == ["before", "rewind", "cancelled"]
    assert session.experiment_steps[-1].reason == "noAnswer"
    assert session.request_headers == {"bcm": "70E", "bms": "17FC0010"}


def test_missing_markers_file_means_no_markers(tmp_path: Path) -> None:
    session = load_session(SessionLog("aaaa0001").write(tmp_path))
    assert session.readings == ()
    assert session.experiment_steps == ()


def test_bad_line_names_file_and_line(tmp_path: Path) -> None:
    buffer = SessionLog("aaaa0001").write(tmp_path)
    with buffer.open("a", encoding="utf-8") as lines:
        lines.write(json.dumps({"sequence": 1, "signalId": "nounderscore"}) + "\n")
    with pytest.raises(LogError, match=r"aaaa0001\.jsonl:2:"):
        load_session(buffer)


def test_bad_marker_names_file_and_line(tmp_path: Path) -> None:
    log = SessionLog("aaaa0001")
    log.markers.append({"type": "reading", "quantity": "soc"})
    with pytest.raises(LogError, match=r"markers\.jsonl:1:"):
        load_session(log.write(tmp_path))


def test_find_buffers_selects_by_prefix_and_skips_marker_files(tmp_path: Path) -> None:
    for session_id in ["aaaa0001", "aaaa0002", "bbbb0001"]:
        log = SessionLog(session_id)
        log.reading("soc", 1, BASE_MS)
        log.write(tmp_path)
    assert [p.name for p in find_buffers(tmp_path, [])] == [
        "aaaa0001.jsonl",
        "aaaa0002.jsonl",
        "bbbb0001.jsonl",
    ]
    assert [p.name for p in find_buffers(tmp_path, ["bbbb", "aaaa0002", "bb"])] == [
        "aaaa0002.jsonl",
        "bbbb0001.jsonl",
    ]
    with pytest.raises(LogError, match="cccc"):
        find_buffers(tmp_path, ["cccc"])
    with pytest.raises(LogError, match="not found"):
        find_buffers(tmp_path / "missing", [])


def test_load_sessions_orders_by_creation_time(tmp_path: Path) -> None:
    SessionLog("aaaa0001", created_ms=BASE_MS + 10).write(tmp_path)
    SessionLog("bbbb0001", created_ms=BASE_MS).write(tmp_path)
    assert [s.id for s in load_sessions(tmp_path, [])] == ["bbbb0001", "aaaa0001"]


def test_session_created_ms_needs_a_unique_prefix(tmp_path: Path) -> None:
    SessionLog("aaaa0001", created_ms=BASE_MS + 10).write(tmp_path)
    SessionLog("aaaa0002").write(tmp_path)
    assert session_created_ms(tmp_path, "aaaa0001") == BASE_MS + 10
    with pytest.raises(LogError, match="matches 2 sessions"):
        session_created_ms(tmp_path, "aaaa")
