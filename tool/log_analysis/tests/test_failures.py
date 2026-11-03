from pathlib import Path

import pytest

from didscout_logs.failures import ReplyCount, find_bursts, group_failures
from didscout_logs.sessions import Session, load_session
from tests.synthetic import BASE_MS, SessionLog, reply


def _write_failures(log: SessionLog, count: int, at_ms: float) -> None:
    for index in range(count):
        log.read(
            "door", f"0{index:03X}", at_ms + index, "", transport="writeFailed", duration_ms=0
        )


def _burst_session(tmp_path: Path) -> Session:
    log = SessionLog("aaaa0001")
    log.positive("door", "0600", BASE_MS, bytes([1]))
    log.read("door", "0610", BASE_MS + 200, reply("7E8037F2231"))
    log.read(
        "door",
        "0611",
        BASE_MS + 400,
        reply("7E8037F2278"),
        transport="timeout",
        duration_ms=2000,
    )
    _write_failures(log, 12, BASE_MS + 2800)
    log.gap()
    log.read("door", "0620", BASE_MS + 2900, "NO DATA\r\r")
    _write_failures(log, 9, BASE_MS + 3000)
    log.positive("door", "0600", BASE_MS + 9000, bytes([1]))
    return load_session(log.write(tmp_path))


def test_find_bursts_reports_runs_with_their_context(tmp_path: Path) -> None:
    session = _burst_session(tmp_path)
    (burst,) = find_bursts(session, min_length=10, context=3)
    assert len(burst.reads) == 12
    assert [read.did for read in burst.preceding] == ["0610", "0611"]
    assert burst.gap_ms == pytest.approx(2800 - 2400)
    assert burst.recovery_ms == pytest.approx(9000 - 2800)


def test_find_bursts_limits_context_and_length(tmp_path: Path) -> None:
    session = _burst_session(tmp_path)
    (burst,) = find_bursts(session, min_length=10, context=1)
    assert [read.did for read in burst.preceding] == ["0611"]
    assert len(find_bursts(session, min_length=9, context=3)) == 2


def test_burst_at_session_start_and_without_recovery(tmp_path: Path) -> None:
    log = SessionLog("aaaa0001")
    _write_failures(log, 10, BASE_MS)
    (burst,) = find_bursts(load_session(log.write(tmp_path)), min_length=10, context=3)
    assert burst.preceding == ()
    assert burst.gap_ms is None
    assert burst.recovery_ms is None


def test_group_failures_decodes_replies(tmp_path: Path) -> None:
    log = SessionLog("aaaa0001")
    for offset in (0, 5000):
        log.read("door", "0611", BASE_MS + offset, reply("7E8037F2278"), transport="timeout")
    log.read("door", "0611", BASE_MS + 9000, "", transport="timeout")
    log.read("door", "0611", BASE_MS + 9500, reply("7E8037F2278"), transport="disconnected")
    log.read("door", "0612", BASE_MS + 9600, reply("7E8037F2231"))
    log.read("bcm", "0100", BASE_MS + 9700, "", transport="writeFailed")
    session = load_session(log.write(tmp_path))
    timeout, write_failed, disconnected = group_failures([session], frozenset(), frozenset())
    assert (timeout.module, timeout.did, timeout.transport) == ("door", "0611", "timeout")
    assert (timeout.count, timeout.sessions) == (3, 1)
    assert timeout.replies == (
        ReplyCount("pending: 7E8 7F 22 78 (responsePending)", 2),
        ReplyCount("empty: (no reply)", 1),
    )
    assert disconnected.transport == "disconnected"
    assert write_failed.module == "bcm"
    only_timeouts = group_failures([session], frozenset(), frozenset({"timeout"}))
    assert [group.transport for group in only_timeouts] == ["timeout"]
    only_bcm = group_failures([session], frozenset({"bcm"}), frozenset())
    assert [group.module for group in only_bcm] == ["bcm"]
