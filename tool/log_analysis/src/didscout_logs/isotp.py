"""ISO-TP reassembly of the frames an ELM327-style adapter prints."""

import re
from dataclasses import dataclass
from typing import Final

_HEX_LINE: Final = re.compile(r"[0-9A-F]+")
_MAX_FRAME_BYTES: Final = 8


@dataclass(frozen=True, slots=True)
class IsoTpMessage:
    """One ISO-TP message from one responder.

    Attributes:
        header: The responder's CAN identifier as the adapter printed
            it: 3 hex digits for 11-bit, 8 for 29-bit identifiers.
        data: The message bytes received, at most `expected_length`.
        expected_length: The length the single or first frame
            announced.
    """

    header: str
    data: bytes
    expected_length: int

    @property
    def complete(self) -> bool:
        """Whether every announced byte arrived."""
        return len(self.data) == self.expected_length


@dataclass(frozen=True, slots=True)
class AdapterReply:
    """An adapter reply split into ISO-TP messages and other lines.

    Attributes:
        messages: Reassembled messages in the order their single or
            first frame arrived, incomplete ones included.
        other_lines: Every non-empty line that is not a usable frame,
            such as `NO DATA`, `CAN ERROR` or an orphaned consecutive
            frame, as printed.
    """

    messages: tuple[IsoTpMessage, ...]
    other_lines: tuple[str, ...]


@dataclass(slots=True)
class _Slot:
    header: str
    expected_length: int
    data: bytearray


def reassemble(text: str) -> AdapterReply:
    """Reassemble the ISO-TP frames in an adapter's reply text.

    The adapter prints one CAN frame per line with headers on: the
    identifier (3 hex digits for 11-bit, 8 for 29-bit, told apart by
    the parity of the line length), then up to 8 data bytes starting
    with the ISO-TP protocol control information. Spaces are ignored.
    A first frame for a responder that still has a message open leaves
    the open one incomplete.

    Args:
        text: The reply as the adapter sent it, lines separated by
            carriage returns or newlines.

    Returns:
        The reassembled messages and the lines that were not frames.
    """
    slots: list[_Slot] = []
    open_slots: dict[str, tuple[_Slot, int]] = {}
    other_lines: list[str] = []
    for line in re.split(r"[\r\n]+", text):
        stripped = line.strip().strip(">").strip()
        if not stripped:
            continue
        frame = _split_frame(stripped)
        if frame is None or not _accept_frame(*frame, slots, open_slots):
            other_lines.append(stripped)
    messages = tuple(
        IsoTpMessage(slot.header, bytes(slot.data), slot.expected_length) for slot in slots
    )
    return AdapterReply(messages, tuple(other_lines))


def _split_frame(line: str) -> tuple[str, bytes] | None:
    flat = line.replace(" ", "").upper()
    if _HEX_LINE.fullmatch(flat) is None:
        return None
    header_length = 3 if len(flat) % 2 else 8
    data = bytes.fromhex(flat[header_length:])
    if not 1 <= len(data) <= _MAX_FRAME_BYTES:
        return None
    return flat[:header_length], data


def _accept_frame(
    header: str,
    data: bytes,
    slots: list[_Slot],
    open_slots: dict[str, tuple[_Slot, int]],
) -> bool:
    match data[0] >> 4:
        case 0x0 if 1 <= (length := data[0] & 0xF) <= len(data) - 1:
            open_slots.pop(header, None)
            slots.append(_Slot(header, length, bytearray(data[1 : 1 + length])))
            return True
        case 0x1 if len(data) == _MAX_FRAME_BYTES:
            length = ((data[0] & 0xF) << 8) | data[1]
            if length <= _MAX_FRAME_BYTES - 1:
                return False
            slot = _Slot(header, length, bytearray(data[2:]))
            slots.append(slot)
            open_slots[header] = (slot, 1)
            return True
        case 0x2 if header in open_slots:
            slot, sequence = open_slots[header]
            if data[0] & 0xF != sequence:
                return False
            slot.data.extend(data[1 : 1 + slot.expected_length - len(slot.data)])
            if len(slot.data) == slot.expected_length:
                del open_slots[header]
            else:
                open_slots[header] = (slot, (sequence + 1) & 0xF)
            return True
        case _:
            return False
