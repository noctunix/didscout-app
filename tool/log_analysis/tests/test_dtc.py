from pathlib import Path

from didscout_logs.dtc import Dtc, decode_dtc, decode_report, fault_memories
from didscout_logs.sessions import load_session
from tests.synthetic import BASE_MS, SessionLog, frames, reply


def test_decode_dtc_maps_the_code_letter_and_status_flags() -> None:
    assert decode_dtc(bytes([0x01, 0x23, 0x45, 0x28])) == Dtc(
        "P0123-45", ("failedSinceClear", "confirmed")
    )
    assert decode_dtc(bytes([0xC1, 0x00, 0x00, 0x89])) == Dtc(
        "U0100-00", ("warningLight", "confirmed", "testFailed")
    )
    assert decode_dtc(bytes([0x5A, 0xBC, 0x01, 0x00])) == Dtc("C1ABC-01", ())


def test_decode_report_splits_the_mask_from_the_records() -> None:
    payload = bytes([0x2F, 0x01, 0x23, 0x45, 0x28, 0x91, 0x00, 0x13, 0x04])
    mask, dtcs = decode_report(payload) or (0, ())
    assert mask == 0x2F
    assert [dtc.code for dtc in dtcs] == ["P0123-45", "B1100-13"]


def test_decode_report_rejects_cut_off_records() -> None:
    assert decode_report(b"") is None
    assert decode_report(bytes([0xFF, 0x01, 0x23])) is None
    assert decode_report(bytes([0xFF])) == (0xFF, ())


def test_fault_memories_reads_a_positive_empty_and_failed_reply(tmp_path: Path) -> None:
    log = SessionLog("aaaa0001")
    full = bytes([0x59, 0x02, 0x2F, 0x01, 0x23, 0x45, 0x28])
    log.command_read("testplanDtc-gateway", "1902FF", BASE_MS, reply(*frames("77A", full)))
    log.command_read(
        "testplanDtc-hud",
        "1902FF",
        BASE_MS + 100,
        reply(*frames("785", bytes([0x59, 0x02, 0xFF]))),
    )
    log.command_read(
        "testplanDtc-eps",
        "1902FF",
        BASE_MS + 200,
        reply(*frames("77C", bytes([0x7F, 0x19, 0x11]))),
    )
    log.command_read("testplanDtc-abs", "1902FF", BASE_MS + 300, "NO DATA\r\r")
    log.command_read(
        "tyres", "2218a0", BASE_MS + 400, reply(*frames("775", bytes([0x7F, 0x22, 0x31])))
    )
    memories = fault_memories([load_session(log.write(tmp_path))])
    assert [(m.module, m.outcome, len(m.dtcs)) for m in memories] == [
        ("gateway", "positive", 1),
        ("hud", "positive", 0),
        ("eps", "NRC 11 serviceNotSupported", 0),
        ("abs", "no data", 0),
    ]
    assert memories[0].availability_mask == 0x2F
    assert memories[1].availability_mask == 0xFF
