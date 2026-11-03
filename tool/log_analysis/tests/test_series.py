from pathlib import Path

import pytest

from didscout_logs.series import DecodeSpec, SeriesPoint, did_series, parse_decode_spec
from didscout_logs.sessions import load_session
from tests.synthetic import BASE_MS, SessionLog


@pytest.mark.parametrize(
    ("text", "spec"),
    [
        ("u16@0*0.125-40", DecodeSpec(0, 2, False, 0.125, -40)),
        ("s8@3", DecodeSpec(3, 1, True, 1, 0)),
        ("u32@1*-1+5.5", DecodeSpec(1, 4, False, -1, 5.5)),
        ("u24@2+100", DecodeSpec(2, 3, False, 1, 100)),
        ("s16@0*.5", DecodeSpec(0, 2, True, 0.5, 0)),
    ],
)
def test_parse_decode_spec(text: str, spec: DecodeSpec) -> None:
    assert parse_decode_spec(text) == spec


@pytest.mark.parametrize("text", ["u12@0", "u16", "x8@0", "u16@0*", "u16@-1", "u8@0 "])
def test_parse_decode_spec_rejects_malformed_specs(text: str) -> None:
    with pytest.raises(ValueError, match="not a decode spec"):
        parse_decode_spec(text)


def test_decode_scales_signed_values_and_rejects_short_payloads() -> None:
    assert parse_decode_spec("u16@1*0.125-40").decode(bytes([9, 0x02, 0x08])) == 25
    assert parse_decode_spec("s16@0").decode(bytes([0xFF, 0xFE])) == -2
    assert parse_decode_spec("u16@2").decode(bytes([1, 2])) is None


def test_did_series_in_time_order_with_changes_only(tmp_path: Path) -> None:
    log = SessionLog("aaaa0001")
    log.positive("bms", "1E10", BASE_MS + 2000, bytes([1]))
    log.positive("bms", "1E10", BASE_MS + 3000, bytes([2]))
    log.positive("bms", "1E10", BASE_MS + 1000, bytes([1]))
    log.positive("bms", "1E11", BASE_MS + 2500, bytes([5]))
    log.positive("other", "1E10", BASE_MS + 2500, bytes([5]))
    log.read("bms", "1E10", BASE_MS + 4000, "NO DATA\r")
    session = load_session(log.write(tmp_path))
    every = did_series([session], "bms", "1e10", changes_only=False)
    assert [(point.at_ms - BASE_MS, point.payload) for point in every] == [
        (1100, bytes([1])),
        (2100, bytes([1])),
        (3100, bytes([2])),
    ]
    changes = did_series([session], "bms", "1E10", changes_only=True)
    assert changes == [
        SeriesPoint("aaaa0001", BASE_MS + 1100, bytes([1])),
        SeriesPoint("aaaa0001", BASE_MS + 3100, bytes([2])),
    ]
