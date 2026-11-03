"""Decoding of UDS and OBD answers in reassembled adapter replies."""

from dataclasses import dataclass
from enum import StrEnum
from typing import Final

from didscout_logs.isotp import AdapterReply, IsoTpMessage

NEGATIVE_RESPONSE: Final = 0x7F
RESPONSE_PENDING: Final = 0x78
_POSITIVE_OFFSET: Final = 0x40
_SHOWN_BYTES: Final = 12

# ISO 14229-1, Annex A.1.
_NRC_NAMES: Final = {
    0x10: "generalReject",
    0x11: "serviceNotSupported",
    0x12: "subFunctionNotSupported",
    0x13: "incorrectMessageLengthOrInvalidFormat",
    0x14: "responseTooLong",
    0x21: "busyRepeatRequest",
    0x22: "conditionsNotCorrect",
    0x24: "requestSequenceError",
    0x25: "noResponseFromSubnetComponent",
    0x26: "failurePreventsExecutionOfRequestedAction",
    0x31: "requestOutOfRange",
    0x33: "securityAccessDenied",
    0x35: "invalidKey",
    0x36: "exceededNumberOfAttempts",
    0x37: "requiredTimeDelayNotExpired",
    0x72: "generalProgrammingFailure",
    RESPONSE_PENDING: "responsePending",
    0x7E: "subFunctionNotSupportedInActiveSession",
    0x7F: "serviceNotSupportedInActiveSession",
}


@dataclass(frozen=True, slots=True)
class Positive:
    """A positive response to the request.

    Attributes:
        payload: The bytes after the echoed request, e.g. the data
            after `62 <did>` for ReadDataByIdentifier.
    """

    payload: bytes


@dataclass(frozen=True, slots=True)
class Negative:
    """A final negative response to the request's service.

    Attributes:
        nrc: The negative response code; never responsePending.
    """

    nrc: int


class NoAnswerReason(StrEnum):
    """Why a reply holds no positive and no final negative answer."""

    INCOMPLETE = "incomplete"
    PENDING = "pending"
    NO_DATA = "no data"
    EMPTY = "empty"
    UNRECOGNIZED = "unrecognized"


@dataclass(frozen=True, slots=True)
class NoAnswer:
    """A reply without a final answer to the request.

    Attributes:
        reason: What the reply held instead.
    """

    reason: NoAnswerReason


type Outcome = Positive | Negative | NoAnswer


def nrc_name(nrc: int) -> str:
    """Name a negative response code.

    Args:
        nrc: The negative response code.

    Returns:
        The ISO 14229-1 name, or the hex code for an unlisted one.
    """
    return _NRC_NAMES.get(nrc, f"nrc{nrc:02X}")


def decode_reply(request: bytes, reply: AdapterReply) -> Outcome:
    """Find the answer to a request in a reassembled reply.

    A complete message that echoes the request with the positive
    service id wins wherever it appears; replies to other requests in
    the same text are skipped. Otherwise the last negative response to
    the request's service other than responsePending is the answer. A
    reply holding nothing better falls back, in this order, to an
    incomplete message, a responsePending without a final answer,
    `NO DATA`, an empty reply, or an unrecognized one.

    Args:
        request: The request bytes, service id first.
        reply: The adapter's reassembled reply.

    Returns:
        The outcome of the request.
    """
    positive_prefix = bytes([request[0] + _POSITIVE_OFFSET]) + request[1:]
    final_nrc: int | None = None
    pending = False
    incomplete = False
    for message in reply.messages:
        if not message.complete:
            incomplete = True
        elif message.data.startswith(positive_prefix):
            return Positive(message.data[len(positive_prefix) :])
        elif _is_negative(message.data, request[0]):
            if message.data[2] == RESPONSE_PENDING:
                pending = True
            else:
                final_nrc = message.data[2]
    if final_nrc is not None:
        return Negative(final_nrc)
    if incomplete:
        return NoAnswer(NoAnswerReason.INCOMPLETE)
    if pending:
        return NoAnswer(NoAnswerReason.PENDING)
    if "NO DATA" in reply.other_lines:
        return NoAnswer(NoAnswerReason.NO_DATA)
    if not reply.messages and not reply.other_lines:
        return NoAnswer(NoAnswerReason.EMPTY)
    return NoAnswer(NoAnswerReason.UNRECOGNIZED)


def outcome_label(outcome: Outcome) -> str:
    """Name an outcome in a few words.

    Args:
        outcome: A decoded outcome.

    Returns:
        `positive`, the NRC with its name, or the no-answer reason.
    """
    match outcome:
        case Positive():
            return "positive"
        case Negative(nrc=nrc):
            return f"NRC {nrc:02X} {nrc_name(nrc)}"
        case NoAnswer(reason=reason):
            return reason.value


def describe_reply(reply: AdapterReply) -> str:
    """Summarize a reassembled reply on one line.

    Each message shows its header, its first bytes, and the NRC name of
    a negative response or the received/announced length of an
    incomplete message; other lines appear verbatim.

    Args:
        reply: The adapter's reassembled reply.

    Returns:
        The parts joined by ` | `, or `(no reply)` for an empty reply.
    """
    parts = [_describe_message(message) for message in reply.messages]
    parts.extend(reply.other_lines)
    return " | ".join(parts) if parts else "(no reply)"


def _describe_message(message: IsoTpMessage) -> str:
    shown = message.data[:_SHOWN_BYTES].hex(" ").upper()
    if len(message.data) > _SHOWN_BYTES:
        shown += " ..."
    text = f"{message.header} {shown}"
    if len(message.data) >= 3 and message.data[0] == NEGATIVE_RESPONSE:
        text += f" ({nrc_name(message.data[2])})"
    if not message.complete:
        text += f" (incomplete {len(message.data)}/{message.expected_length})"
    return text


def _is_negative(data: bytes, service: int) -> bool:
    return len(data) >= 3 and data[0] == NEGATIVE_RESPONSE and data[1] == service
