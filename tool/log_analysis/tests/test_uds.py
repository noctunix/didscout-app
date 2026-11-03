import pytest

from didscout_logs.isotp import reassemble
from didscout_logs.uds import (
    Negative,
    NoAnswer,
    NoAnswerReason,
    Outcome,
    Positive,
    decode_reply,
    describe_reply,
    nrc_name,
    outcome_label,
)

READ_1234 = bytes.fromhex("221234")


def decode(text: str, request: bytes = READ_1234) -> Outcome:
    return decode_reply(request, reassemble(text))


def test_positive_single_frame() -> None:
    assert decode("7E80562123401FF\r") == Positive(bytes.fromhex("01FF"))


def test_positive_multi_frame_29_bit() -> None:
    text = "18DAF110100A621234010203\r18DAF1102104050607AAAAAA\r"
    assert decode(text) == Positive(bytes.fromhex("01020304050607"))


def test_positive_with_empty_payload() -> None:
    assert decode("7E803621234\r") == Positive(b"")


def test_response_pending_followed_by_real_answer() -> None:
    assert decode("7E8037F2278\r7E80462123442\r") == Positive(bytes.fromhex("42"))


def test_response_pending_followed_by_negative_answer() -> None:
    assert decode("7E8037F2278\r7E8037F2231\r") == Negative(0x31)


def test_response_pending_without_final_answer() -> None:
    assert decode("7E8037F2278\r") == NoAnswer(NoAnswerReason.PENDING)


def test_truncated_answer_after_response_pending_is_incomplete() -> None:
    text = "7E8037F2278\r7E8100A621234FFFFFF\r"
    assert decode(text) == NoAnswer(NoAnswerReason.INCOMPLETE)


def test_negative_for_another_service_is_ignored() -> None:
    assert decode("7E8037F1931\r") == NoAnswer(NoAnswerReason.UNRECOGNIZED)


def test_late_answer_for_another_did_is_skipped() -> None:
    text = "7E80462123301\r7E80462123402\r"
    assert decode(text) == Positive(bytes.fromhex("02"))
    assert decode("7E80462123301\r") == NoAnswer(NoAnswerReason.UNRECOGNIZED)


def test_no_data() -> None:
    assert decode("NO DATA\r\r") == NoAnswer(NoAnswerReason.NO_DATA)


def test_empty_reply() -> None:
    assert decode("") == NoAnswer(NoAnswerReason.EMPTY)


def test_obd_mode_01_positive() -> None:
    assert decode("7E804410D3200\r", bytes.fromhex("010D")) == Positive(bytes.fromhex("3200"))


@pytest.mark.parametrize(
    ("nrc", "name"),
    [(0x31, "requestOutOfRange"), (0x78, "responsePending"), (0x99, "nrc99")],
)
def test_nrc_name(nrc: int, name: str) -> None:
    assert nrc_name(nrc) == name


def test_outcome_label() -> None:
    assert outcome_label(Positive(b"")) == "positive"
    assert outcome_label(Negative(0x22)) == "NRC 22 conditionsNotCorrect"
    assert outcome_label(NoAnswer(NoAnswerReason.NO_DATA)) == "no data"


def test_describe_reply_names_nrcs_and_incomplete_messages() -> None:
    text = "7E8037F2278\r7E8100A621234010203\r"
    assert describe_reply(reassemble(text)) == (
        "7E8 7F 22 78 (responsePending) | 7E8 62 12 34 01 02 03 (incomplete 6/10)"
    )


def test_describe_reply_shortens_long_messages() -> None:
    text = "7E8100E621234010203\r7E8210405060708090A\r7E8220BAAAAAAAAAAAA\r"
    assert describe_reply(reassemble(text)) == "7E8 62 12 34 01 02 03 04 05 06 07 08 09 ..."


def test_describe_reply_keeps_other_lines_and_empty_reply() -> None:
    assert describe_reply(reassemble("NO DATA\r")) == "NO DATA"
    assert describe_reply(reassemble("")) == "(no reply)"
