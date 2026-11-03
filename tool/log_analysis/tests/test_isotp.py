from didscout_logs.isotp import IsoTpMessage, reassemble


def test_single_frame_11_bit() -> None:
    result = reassemble("7E80462123401\r\r")
    assert result.messages == (IsoTpMessage("7E8", bytes.fromhex("62123401"), 4),)
    assert result.other_lines == ()


def test_spaces_and_lower_case_and_prompt_are_tolerated() -> None:
    result = reassemble("7e8 04 62 12 34 01\r\r>")
    assert result.messages == (IsoTpMessage("7E8", bytes.fromhex("62123401"), 4),)


def test_single_frame_ignores_padding() -> None:
    result = reassemble("7E80362123455AAAAAA\r")
    assert result.messages[0].data == bytes.fromhex("621234")


def test_single_frame_29_bit() -> None:
    result = reassemble("18DAF1100462ABCD07\r")
    assert result.messages == (IsoTpMessage("18DAF110", bytes.fromhex("62ABCD07"), 4),)


def test_multi_frame_11_bit() -> None:
    result = reassemble("7E8100A621234010203\r7E82104050607AAAAAA\r\r")
    message = result.messages[0]
    assert message.data == bytes.fromhex("62123401020304050607")
    assert message.complete
    assert result.other_lines == ()


def test_multi_frame_29_bit() -> None:
    text = "18DAF110100D62ABCD010203\r18DAF110210405060708090A\r18DAF11022AAAAAAAAAAAAAA\r"
    result = reassemble(text)
    assert result.messages == (
        IsoTpMessage("18DAF110", bytes.fromhex("62ABCD0102030405060708090A"), 13),
    )
    assert result.other_lines == ("18DAF11022AAAAAAAAAAAAAA",)


def test_consecutive_frame_sequence_wraps_after_f() -> None:
    data = bytes(range(130))
    lines = [f"7E81082{data[:6].hex().upper()}"]
    rest = data[6:]
    sequence = 1
    while rest:
        lines.append(f"7E82{sequence:X}{rest[:7].ljust(7, b'\x00').hex().upper()}")
        rest = rest[7:]
        sequence = (sequence + 1) % 16
    result = reassemble("\r".join(lines))
    assert result.messages[0].data == data
    assert result.messages[0].complete


def test_missing_consecutive_frame_leaves_message_incomplete() -> None:
    result = reassemble("7E8100A621234010203\r")
    message = result.messages[0]
    assert not message.complete
    assert message.data == bytes.fromhex("621234010203")
    assert message.expected_length == 10


def test_out_of_sequence_frame_is_not_used() -> None:
    result = reassemble("7E8100A621234010203\r7E82204050607AAAAAA\r")
    assert not result.messages[0].complete
    assert result.other_lines == ("7E82204050607AAAAAA",)


def test_orphan_consecutive_frame_is_another_line() -> None:
    result = reassemble("7E82104050607AAAAAA\r")
    assert result.messages == ()
    assert result.other_lines == ("7E82104050607AAAAAA",)


def test_no_data_and_status_lines() -> None:
    result = reassemble("SEARCHING...\rNO DATA\r\r")
    assert result.messages == ()
    assert result.other_lines == ("SEARCHING...", "NO DATA")


def test_empty_reply() -> None:
    result = reassemble("")
    assert result.messages == ()
    assert result.other_lines == ()


def test_interleaved_responders_are_kept_apart() -> None:
    text = "7E81008621234010203\r7E903621111\r7E82104050000000000\r"
    result = reassemble(text)
    assert result.messages == (
        IsoTpMessage("7E8", bytes.fromhex("6212340102030405"), 8),
        IsoTpMessage("7E9", bytes.fromhex("621111"), 3),
    )


def test_new_message_from_same_responder_abandons_open_one() -> None:
    result = reassemble("7E8100A621234010203\r7E8037F2278\r")
    first, second = result.messages
    assert not first.complete
    assert second == IsoTpMessage("7E8", bytes.fromhex("7F2278"), 3)


def test_frames_that_are_too_long_or_bad_length_are_other_lines() -> None:
    result = reassemble("7E80962123401020304050607\r7E8076212\r")
    assert result.messages == ()
    assert len(result.other_lines) == 2
