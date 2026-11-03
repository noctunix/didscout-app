"""Grouping of failed reads and runs of write failures."""

from collections import Counter, defaultdict
from collections.abc import Iterable
from dataclasses import dataclass

from didscout_logs.isotp import reassemble
from didscout_logs.sessions import TRANSPORT_OK, TRANSPORT_WRITE_FAILED, Read, Session
from didscout_logs.uds import describe_reply, outcome_label


@dataclass(frozen=True, slots=True)
class ReplyCount:
    """How often one decoded reply occurred.

    Attributes:
        description: The outcome and the reply summary.
        count: The number of reads with this reply.
    """

    description: str
    count: int


@dataclass(frozen=True, slots=True)
class FailureGroup:
    """The failed reads of one DID with one transport result.

    Attributes:
        module: The module id.
        did: The DID.
        transport: The transport result, e.g. `timeout`.
        count: The number of reads.
        sessions: The number of sessions they occurred in.
        replies: The distinct decoded replies, most frequent first.
    """

    module: str
    did: str
    transport: str
    count: int
    sessions: int
    replies: tuple[ReplyCount, ...]


@dataclass(frozen=True, slots=True)
class Burst:
    """A run of consecutive write failures.

    Attributes:
        reads: The failed reads, in order.
        preceding: The non-positive reads right before the run, oldest
            first; reading back stops at a positive read.
        gap_ms: The time from the end of the read right before the run
            to the run's first request; None at the session start.
        recovery_ms: The time from the run's first request to the next
            positive read; None if none followed.
    """

    reads: tuple[Read, ...]
    preceding: tuple[Read, ...]
    gap_ms: float | None
    recovery_ms: float | None


def describe_read(read: Read) -> str:
    """Summarize a read's decoded outcome and reply on one line.

    Args:
        read: The read.

    Returns:
        The outcome label and the reply summary.
    """
    return f"{outcome_label(read.outcome)}: {describe_reply(reassemble(read.reply_text))}"


def group_failures(
    sessions: Iterable[Session], modules: frozenset[str], transports: frozenset[str]
) -> list[FailureGroup]:
    """Group every read whose transport was not `ok`.

    Args:
        sessions: The sessions to search.
        modules: Only these module ids; empty means every module.
        transports: Only these transport results; empty means every
            one but `ok`.

    Returns:
        One group per module, DID and transport result, the largest
        first.
    """
    groups: dict[tuple[str, str, str], list[Read]] = defaultdict(list)
    for session in sessions:
        for read in session.reads:
            if (
                read.transport != TRANSPORT_OK
                and (not transports or read.transport in transports)
                and (not modules or read.module in modules)
            ):
                groups[(read.module, read.did, read.transport)].append(read)
    result = [
        FailureGroup(
            module=module,
            did=did,
            transport=transport,
            count=len(reads),
            sessions=len({read.session_id for read in reads}),
            replies=tuple(
                ReplyCount(description, count)
                for description, count in Counter(map(describe_read, reads)).most_common()
            ),
        )
        for (module, did, transport), reads in groups.items()
    ]
    return sorted(
        result, key=lambda group: (-group.count, group.module, group.did, group.transport)
    )


def find_bursts(session: Session, *, min_length: int, context: int) -> list[Burst]:
    """Find the runs of consecutive write failures in a session.

    Args:
        session: The session to search.
        min_length: The fewest consecutive write failures that count.
        context: The most preceding non-positive reads to keep.

    Returns:
        The runs, in session order.
    """
    reads = session.reads
    bursts: list[Burst] = []
    start = 0
    while start < len(reads):
        end = start
        while end < len(reads) and reads[end].transport == TRANSPORT_WRITE_FAILED:
            end += 1
        if end - start >= min_length:
            bursts.append(_burst(reads, start, end, context))
        start = max(end, start + 1)
    return bursts


def _burst(reads: tuple[Read, ...], start: int, end: int, context: int) -> Burst:
    first = reads[start]
    preceding: list[Read] = []
    index = start - 1
    while index >= 0 and len(preceding) < context and reads[index].payload is None:
        preceding.insert(0, reads[index])
        index -= 1
    recovery = next((read for read in reads[end:] if read.payload is not None), None)
    return Burst(
        reads=reads[start:end],
        preceding=tuple(preceding),
        gap_ms=first.started_ms - reads[start - 1].end_ms if start else None,
        recovery_ms=recovery.started_ms - first.started_ms if recovery else None,
    )
