from pathlib import Path

from didscout_logs.sessions import load_session
from didscout_logs.testplan import (
    HeaderReply,
    Probe,
    SupportedPids,
    decode_bitmap,
    describe_payload,
    summarize_testplan,
)
from didscout_logs.testplan import testplan_catalogue as load_catalogue
from didscout_logs.uds import Positive
from tests.synthetic import BASE_MS, SessionLog, frames, mode1_reply, reply

_CATALOGUE = load_catalogue()


def _probe(module: str, request: str) -> Probe:
    for probe in _CATALOGUE:
        if probe.module == module and probe.request == request:
            return probe
    raise AssertionError(f"no probe {module} {request!r}")


def test_catalogue_has_one_probe_per_module_and_request() -> None:
    pairs = [(probe.module, probe.request) for probe in _CATALOGUE]
    assert len(pairs) == 61
    assert len(set(pairs)) == len(pairs)


def test_decode_bitmap_lists_supported_pids_and_next_range_flag() -> None:
    payload = bytes([0xC0, 0x00, 0x01, 0x01])
    assert decode_bitmap(payload, 0x00) == SupportedPids(("01", "02", "18"), True)
    assert decode_bitmap(payload, 0x20) == SupportedPids(("21", "22", "38"), True)


def test_decode_bitmap_too_short_returns_none() -> None:
    assert decode_bitmap(bytes([0xC0, 0x00, 0x00]), 0x00) is None


def test_bitmap_probe_decode_via_describe_payload() -> None:
    probe = _probe("testplanUds04", "F420")
    payload = bytes([0xC0, 0x00, 0x01, 0x01])
    assert describe_payload(probe, payload) == "C0 00 01 01  PIDs 21 22 38, next range supported"


def test_bitmap_probe_short_payload_prints_hex_only() -> None:
    probe = _probe("testplanMode1", "0100")
    assert describe_payload(probe, bytes([0xC0, 0x00, 0x00])) == "C0 00 00"


def test_value_probe_has_no_decode() -> None:
    probe = _probe("testplanMode1", "015B")
    assert describe_payload(probe, bytes([0x12, 0x34])) == "12 34"


def test_2af7_hypothesis_decode_is_unverified() -> None:
    probe = _probe("testplanGateway", "2AF7")
    payload = bytearray(23)
    payload[0:2] = (4000).to_bytes(2, "big")
    payload[2:6] = (-1234).to_bytes(4, "big", signed=True)
    payload[7] = 55
    payload[8] = 10
    payload[9] = 60
    payload[20] = 77
    payload[21] = 88
    payload[22] = 33
    text = describe_payload(probe, bytes(payload))
    assert text.endswith(
        "unverified: V=8V I=-1234mA 12V_SoC=55% temp1=-30C temp2=20C pct1=77% pct2=88% Ah=33Ah"
    )


def test_2ab2_hypothesis_decode_is_unverified() -> None:
    probe = _probe("testplanGateway", "2AB2")
    payload = (10).to_bytes(2, "big")
    assert describe_payload(probe, payload).endswith("unverified: value=500")


def test_2ab6_hypothesis_decode_is_verified() -> None:
    probe = _probe("testplanGateway", "2AB6")
    payload = (321).to_bytes(2, "big")
    assert describe_payload(probe, payload).endswith("verified: range=321km")


def test_2ab7_hypothesis_decode_is_unverified() -> None:
    probe = _probe("testplanGateway", "2AB7")
    payload = b"".join(value.to_bytes(2, "big") for value in (100, 200, 300, 400, 500, 600, 700))
    assert describe_payload(probe, payload).endswith(
        "unverified: f0=10 f1=20 f2=30 f3=40 f4=50 f5=60 f6=70"
    )


def test_2ab8_hypothesis_decode_is_verified() -> None:
    probe = _probe("testplanGateway", "2AB8")
    payload = bytes([0, 0]) + (4).to_bytes(2, "big")
    assert describe_payload(probe, payload).endswith("verified: energy=100Wh")


def test_tyre_pressure_hypothesis_decode_is_unverified() -> None:
    probe = _probe("testplanTyres", "18A1")
    payload = bytes(5) + bytes([100])
    assert describe_payload(probe, payload).endswith("unverified: pressure=2.5bar")


def test_hypothesis_too_short_prints_hex_only_no_exception() -> None:
    probe = _probe("testplanGateway", "2AB8")
    assert describe_payload(probe, bytes([0xAB, 0xCD])) == "AB CD"


def test_mode1_probe_reports_each_responding_header(tmp_path: Path) -> None:
    payload_a = bytes([0xC0, 0x00, 0x00, 0x00])
    payload_b = bytes([0x00, 0x80, 0x00, 0x00])
    log = SessionLog("aaaa0001")
    log.mode1_read(
        "testplanMode1",
        "00",
        BASE_MS,
        mode1_reply([("7E8", payload_a), ("7E9", payload_b)], "00"),
    )
    session = load_session(log.write(tmp_path))
    assert session.reads[0].outcome == Positive(payload_a)

    summaries = summarize_testplan([session])
    summary = next(
        s for s in summaries if s.probe.module == "testplanMode1" and s.probe.request == "0100"
    )
    assert summary.sessions == 1
    assert [outcome.label for outcome in summary.outcomes] == ["positive"]
    assert summary.latest == (
        HeaderReply("7E8", payload_a),
        HeaderReply("7E9", payload_b),
    )


def test_outcome_counts_and_latest_positive_across_sessions(tmp_path: Path) -> None:
    module, did = "testplanUds04", "F45B"

    negative = reply(*frames("18DAF104", bytes([0x7F, 0x22, 0x31])))
    session_a = SessionLog("aaaa0001")
    session_a.positive(module, did, BASE_MS, bytes([0x11]), header="18DAF104")
    session_a.read(module, did, BASE_MS + 1000, negative)
    session_a.positive(module, did, BASE_MS + 2000, bytes([0x22]), header="18DAF104")

    session_b = SessionLog("bbbb0001", created_ms=BASE_MS + 100_000)
    session_b.read(module, did, BASE_MS + 100_000, "", transport="timeout")

    sessions = [
        load_session(session_a.write(tmp_path)),
        load_session(session_b.write(tmp_path)),
    ]
    summaries = summarize_testplan(sessions)
    summary = next(s for s in summaries if s.probe.module == module and s.probe.request == did)
    assert summary.sessions == 2
    assert {outcome.label: outcome.count for outcome in summary.outcomes} == {
        "positive": 2,
        "NRC 31 requestOutOfRange": 1,
        "timeout": 1,
    }
    assert summary.latest == (HeaderReply("18DAF104", bytes([0x22])),)
