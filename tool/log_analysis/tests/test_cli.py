from datetime import UTC, datetime
from pathlib import Path

import pytest

from didscout_logs.cli import main
from tests.synthetic import BASE_MS, SessionLog, reply

S = 1000
DAY_MS = 86_400_000


@pytest.fixture
def logs(tmp_path: Path) -> Path:
    directory = tmp_path / "logs"
    directory.mkdir()
    old = SessionLog("aaaa0001", created_ms=BASE_MS)
    for step in range(20):
        old.positive("bms", "1E10", BASE_MS + step * 10 * S, (400 + step * 8).to_bytes(2))
    for step in range(0, 18, 3):
        old.reading("charge_power", 10 + step, BASE_MS + step * 10 * S + 100)
    old.read("door", "0611", BASE_MS + 205 * S, reply("7E8037F2278"), transport="timeout")
    for index in range(10):
        old.read("door", f"07{index:02X}", BASE_MS + 207 * S, "", transport="writeFailed")
    old.positive("door", "0611", BASE_MS + 220 * S, bytes([1]))
    old.write(directory)

    new = SessionLog("bbbb0001", created_ms=BASE_MS + DAY_MS)
    new.experiment("fan", "before", BASE_MS + DAY_MS)
    new.positive("climate", "0100", BASE_MS + DAY_MS + 1 * S, bytes([0, 1]))
    new.experiment("fan", "action", BASE_MS + DAY_MS + 2 * S)
    new.experiment("fan", "after", BASE_MS + DAY_MS + 3 * S)
    new.positive("climate", "0100", BASE_MS + DAY_MS + 4 * S, bytes([0, 3]))
    new.experiment("door", "before", BASE_MS + DAY_MS + 10 * S)
    new.experiment("door", "cancelled", BASE_MS + DAY_MS + 11 * S, reason="noAnswer")
    new.markers.append(
        {
            "type": "plan",
            "planId": "p",
            "planVersion": 1,
            "at": "2023-11-15T00:00:00Z",
            "modules": [{"id": "climate", "request": "767", "response": "7D1", "protocol": "6"}],
        }
    )
    new.write(directory)
    return directory


def run(capsys: pytest.CaptureFixture[str], *args: str) -> list[str]:
    assert main(list(args)) == 0
    return capsys.readouterr().out.splitlines()


def test_fit_with_alias_before_date(capsys: pytest.CaptureFixture[str], logs: Path) -> None:
    cutoff = datetime.fromtimestamp((BASE_MS + DAY_MS) / 1000, UTC).strftime("%Y-%m-%dT%H:%M:%S")
    out = run(
        capsys,
        "fit",
        "charge_power_max",
        "--logs",
        str(logs),
        "--alias",
        "charge_power=charge_power_max",
        "--before",
        cutoff,
        "--min-n",
        "3",
        "--top",
        "1",
    )
    assert out[0] == "charge_power_max: 6 readings in 1 sessions, 4 candidates"
    assert out[2].split() == ["module", "DID", "feature", "n", "r", "a", "b", "p90", "max"]
    assert out[3].split()[:5] == ["bms", "1E10", "u16@0", "6", "1.0000"]
    assert len(out) == 4


def test_fit_alias_before_session_excludes_that_session(
    capsys: pytest.CaptureFixture[str], logs: Path
) -> None:
    common = [
        "fit",
        "charge_power_max",
        "--logs",
        str(logs),
        "--alias",
        "charge_power=charge_power_max",
    ]
    assert run(capsys, *common, "--before", "aaaa")[0].startswith("charge_power_max: 0 readings")
    assert run(capsys, *common, "--before", "bbbb")[0].startswith("charge_power_max: 6 readings")


def test_fit_rejects_malformed_alias(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit):
        main(["fit", "soc", "--alias", "nothing"])
    assert "RECORDED=MEANT" in capsys.readouterr().err


def test_timeouts(capsys: pytest.CaptureFixture[str], logs: Path) -> None:
    out = run(capsys, "timeouts", "--logs", str(logs), "--transport", "timeout")
    assert out[0].split() == ["transport", "reads", "DIDs"]
    assert out[1].split() == ["timeout", "1", "1"]
    assert out[3] == "door 0611  timeout  1 reads in 1 sessions"
    assert out[4].split(maxsplit=1)[1] == "pending: 7E8 7F 22 78 (responsePending)"


def test_bursts(capsys: pytest.CaptureFixture[str], logs: Path) -> None:
    out = run(capsys, "bursts", "--logs", str(logs), "--sessions", "aaaa")
    assert out[0].startswith("aaaa0001  2023-11-14 22:")
    assert "10 writeFailed" in out[0]
    assert "next positive 13.00 s" in out[0]
    assert out[2].split()[:5] == ["-2.00", "s", "door", "0611", "timeout"]


def test_experiments(capsys: pytest.CaptureFixture[str], logs: Path) -> None:
    out = run(capsys, "experiments", "--logs", str(logs))
    assert out[0].startswith("bbbb0001  fan  before 2023-11-15 22:")
    assert out[2].split() == ["climate", "(767)", "0100", "[1]", "01->03"]
    assert out[4].startswith("bbbb0001  door  before")
    assert out[5].strip() == "no after reads (noAnswer)"


def test_series_with_decode_and_readings(capsys: pytest.CaptureFixture[str], logs: Path) -> None:
    out = run(
        capsys,
        "series",
        "bms",
        "1e10",
        "--logs",
        str(logs),
        "--decode",
        "u16@0*0.125-40",
        "--quantity",
        "charge_power",
    )
    assert out[0].split() == ["local", "UTC", "session", "value", "payload"]
    assert out[1].split()[-3:] == ["10", "01", "90"]
    assert out[2].endswith("<- reading charge_power = 10 (typed)")
    assert len(out) == 1 + 20 + 6


def test_series_rejects_bad_spec(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit):
        main(["series", "bms", "1E10", "--decode", "f16@0"])
    assert "not a decode spec" in capsys.readouterr().err


def test_unusable_logs_dir_exits_with_error(
    capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    assert main(["timeouts", "--logs", str(tmp_path / "missing")]) == 1
    assert "logs directory not found" in capsys.readouterr().err


def test_default_logs_dir_is_found_above_the_working_directory(
    capsys: pytest.CaptureFixture[str], logs: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    (logs.parent / "pubspec.yaml").write_text("name: x\n", encoding="utf-8")
    nested = logs.parent / "tool" / "x"
    nested.mkdir(parents=True)
    monkeypatch.chdir(nested)
    assert run(capsys, "experiments")[0].startswith("bbbb0001  fan")
