import math
from pathlib import Path

from didscout_logs.experiments import (
    ByteChange,
    DidChange,
    diff_bytes,
    experiment_runs,
    run_changes,
)
from didscout_logs.sessions import load_session
from tests.synthetic import BASE_MS, SessionLog

S = 1000


def test_diff_bytes_compares_the_common_length() -> None:
    assert diff_bytes(bytes([1, 2, 3]), bytes([1, 9, 3, 4])) == (ByteChange(1, 2, 9),)
    assert diff_bytes(b"", bytes([1])) == ()


def test_runs_split_at_before_steps(tmp_path: Path) -> None:
    log = SessionLog("aaaa0001")
    log.experiment("door", "before", BASE_MS)
    log.experiment("door", "cancelled", BASE_MS + 10 * S, reason="moving")
    log.experiment("fan", "before", BASE_MS + 20 * S)
    log.experiment("fan", "action", BASE_MS + 30 * S)
    log.experiment("fan", "after", BASE_MS + 40 * S)
    log.experiment("fan", "someday", BASE_MS + 45 * S)
    log.experiment("fan", "undo", BASE_MS + 50 * S)
    log.experiment("old", "cancelled", BASE_MS + 60 * S)
    log.experiment("lights", "before", BASE_MS + 70 * S)
    log.experiment("lights", "cancelled", BASE_MS + 80 * S)
    door, fan, lights = experiment_runs(load_session(log.write(tmp_path)))
    assert (door.experiment_id, door.cancel_reason) == ("door", "moving")
    assert door.end_ms == BASE_MS + 20 * S
    assert [step.step for step in fan.steps] == ["before", "action", "after", "someday", "undo"]
    assert fan.cancel_reason is None
    assert fan.at("undo") == BASE_MS + 50 * S
    assert fan.at("missing") is None
    assert lights.cancel_reason == "cancelled"
    assert lights.end_ms == math.inf


def test_run_changes_compares_last_before_with_first_after(tmp_path: Path) -> None:
    log = SessionLog("aaaa0001")
    log.experiment("fan", "before", BASE_MS)
    log.positive("climate", "0100", BASE_MS + 1 * S, bytes([0, 5, 7]))
    log.positive("climate", "0101", BASE_MS + 2 * S, bytes([1]))
    log.positive("climate", "0102", BASE_MS + 3 * S, bytes([1, 1]))
    log.positive("climate", "0102", BASE_MS + 4 * S, bytes([1, 2]))
    log.positive("other", "0100", BASE_MS + 4 * S, bytes([3]))
    log.experiment("fan", "action", BASE_MS + 5 * S)
    log.positive("climate", "0100", BASE_MS + 6 * S, bytes([0xFF, 0xFF, 0xFF]))
    log.experiment("fan", "after", BASE_MS + 10 * S)
    log.positive("climate", "0100", BASE_MS + 11 * S, bytes([0, 6, 8]))
    log.positive("climate", "0100", BASE_MS + 12 * S, bytes([0, 0, 0]))
    log.positive("climate", "0101", BASE_MS + 11 * S, bytes([1]))
    log.positive("climate", "0102", BASE_MS + 11 * S, bytes([1, 2, 0]))
    log.positive("other", "0100", BASE_MS + 11 * S, bytes([4]))
    log.positive("climate", "0103", BASE_MS + 11 * S, bytes([4]))
    session = load_session(log.write(tmp_path))
    (run,) = experiment_runs(session)
    changes = run_changes(session, run, frozenset())
    assert changes == [
        DidChange("climate", "0100", bytes([0, 5, 7]), bytes([0, 6, 8]), None, False),
        DidChange("climate", "0102", bytes([1, 2]), bytes([1, 2, 0]), None, True),
        DidChange("other", "0100", bytes([3]), bytes([4]), None, False),
    ]
    only_climate = run_changes(session, run, frozenset({"climate"}))
    assert only_climate is not None
    assert {change.module for change in only_climate} == {"climate"}


def test_run_changes_reads_the_undo_window(tmp_path: Path) -> None:
    log = SessionLog("aaaa0001")
    log.experiment("ac", "before", BASE_MS)
    log.positive("climate", "0100", BASE_MS + 1 * S, bytes([0]))
    log.positive("climate", "0101", BASE_MS + 1 * S, bytes([0]))
    log.experiment("ac", "action", BASE_MS + 2 * S)
    log.experiment("ac", "after", BASE_MS + 3 * S)
    log.positive("climate", "0100", BASE_MS + 4 * S, bytes([1]))
    log.positive("climate", "0101", BASE_MS + 4 * S, bytes([1]))
    log.experiment("ac", "undo", BASE_MS + 5 * S)
    # Read while the owner is still undoing: not the undo value.
    log.positive("climate", "0100", BASE_MS + 5.2 * S, bytes([7]))
    log.experiment("ac", "undone", BASE_MS + 5.5 * S)
    log.positive("climate", "0100", BASE_MS + 6 * S, bytes([0]))
    log.experiment("next", "before", BASE_MS + 7 * S)
    log.positive("climate", "0101", BASE_MS + 8 * S, bytes([0]))
    session = load_session(log.write(tmp_path))
    run = experiment_runs(session)[0]
    assert run_changes(session, run, frozenset()) == [
        DidChange("climate", "0100", bytes([0]), bytes([1]), bytes([0]), False),
        DidChange("climate", "0101", bytes([0]), bytes([1]), None, False),
    ]


def test_run_without_after_step_has_no_changes(tmp_path: Path) -> None:
    log = SessionLog("aaaa0001")
    log.experiment("door", "before", BASE_MS)
    log.positive("door", "0100", BASE_MS + 1 * S, bytes([0]))
    log.experiment("door", "cancelled", BASE_MS + 2 * S)
    log.positive("door", "0100", BASE_MS + 3 * S, bytes([1]))
    session = load_session(log.write(tmp_path))
    (run,) = experiment_runs(session)
    assert run_changes(session, run, frozenset()) is None
