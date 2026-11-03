"""Before/after comparison of guided experiment runs."""

import math
from collections import defaultdict
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Final

from didscout_logs.sessions import ExperimentStep, Read, Session

STEP_BEFORE: Final = "before"
STEP_AFTER: Final = "after"
STEP_UNDO: Final = "undo"
STEP_UNDONE: Final = "undone"
STEP_CANCELLED: Final = "cancelled"


@dataclass(frozen=True, slots=True)
class ExperimentRun:
    """One run of an experiment, from its `before` step on.

    Attributes:
        session_id: The session the run belongs to.
        experiment_id: The experiment's catalog id.
        steps: The run's steps, in order, `before` first.
        end_ms: When the next run began, or infinity for the last run
            of a session.
    """

    session_id: str
    experiment_id: str
    steps: tuple[ExperimentStep, ...]
    end_ms: float

    def at(self, step: str) -> float | None:
        """Find when a step began.

        Args:
            step: The step name.

        Returns:
            The first such step's time in Unix milliseconds, or None.
        """
        return next((s.at_ms for s in self.steps if s.step == step), None)

    @property
    def cancel_reason(self) -> str | None:
        """Why the run was cancelled, or None if it was not.

        Runs recorded before the app stored a reason report
        `cancelled`.
        """
        for step in self.steps:
            if step.step == STEP_CANCELLED:
                return step.reason or STEP_CANCELLED
        return None


@dataclass(frozen=True, slots=True)
class ByteChange:
    """One payload byte that differs.

    Attributes:
        position: The byte's index in the payload.
        old: The earlier value.
        new: The later value.
    """

    position: int
    old: int
    new: int


@dataclass(frozen=True, slots=True)
class DidChange:
    """A DID whose payload differed between the before and after reads.

    Attributes:
        module: The module id.
        did: The DID.
        before: The last payload of the before window.
        after: The first payload of the after window.
        undo: The first payload of the undo window, if there is one
            and the DID was read in it.
        moves_alone: Whether the payload already changed within the
            before window.
    """

    module: str
    did: str
    before: bytes
    after: bytes
    undo: bytes | None
    moves_alone: bool


def diff_bytes(old: bytes, new: bytes) -> tuple[ByteChange, ...]:
    """List the differing bytes of two payloads' common length.

    Args:
        old: The earlier payload.
        new: The later payload.

    Returns:
        The changed positions, in order.
    """
    return tuple(
        ByteChange(position, a, b)
        for position, (a, b) in enumerate(zip(old, new, strict=False))
        if a != b
    )


def experiment_runs(session: Session) -> list[ExperimentRun]:
    """Split a session's experiment markers into runs.

    A `before` step starts a run; every later step of the same
    experiment until the next `before` belongs to it. Steps of
    another experiment, unknown steps and steps before the first
    `before` are dropped.

    Args:
        session: The session.

    Returns:
        The runs, in session order.
    """
    starts = [step for step in session.experiment_steps if step.step == STEP_BEFORE]
    runs: list[ExperimentRun] = []
    for index, start in enumerate(starts):
        end_ms = starts[index + 1].at_ms if index + 1 < len(starts) else math.inf
        steps = tuple(
            step
            for step in session.experiment_steps
            if step.experiment_id == start.experiment_id
            and start.at_ms <= step.at_ms < end_ms
            and (step is start or step.step != STEP_BEFORE)
        )
        runs.append(ExperimentRun(session.id, start.experiment_id, steps, end_ms))
    return runs


def run_changes(
    session: Session, run: ExperimentRun, modules: frozenset[str]
) -> list[DidChange] | None:
    """Compare the payloads read before and after an experiment action.

    The before window runs from the `before` step to the next step; its
    last payload of each DID counts. The after window runs from the
    `after` step to the `undo` step (the owner is asked to undo the
    action) or the run's end, the undo window from `undone` (the owner
    did) to the run's end; their first payload counts.

    Args:
        session: The session holding the reads.
        run: The run to compare.
        modules: Only these module ids; empty means every module.

    Returns:
        The changed DIDs sorted by module and DID, or None if the run
        has no `after` step.
    """
    after_ms = run.at(STEP_AFTER)
    if after_ms is None:
        return None
    before_ms = run.steps[0].at_ms
    before_end = run.steps[1].at_ms if len(run.steps) > 1 else run.end_ms
    undo_ms = run.at(STEP_UNDO)
    undone_ms = run.at(STEP_UNDONE)
    before = _window(session.reads, before_ms, before_end, modules)
    after = _window(session.reads, after_ms, run.end_ms if undo_ms is None else undo_ms, modules)
    undo = {} if undone_ms is None else _window(session.reads, undone_ms, run.end_ms, modules)
    changes = [
        DidChange(
            module=key[0],
            did=key[1],
            before=payloads[-1],
            after=after[key][0],
            undo=undo[key][0] if key in undo else None,
            moves_alone=len(set(payloads)) > 1,
        )
        for key, payloads in before.items()
        if key in after and after[key][0] != payloads[-1]
    ]
    return sorted(changes, key=lambda change: (change.module, change.did))


def _window(
    reads: Sequence[Read], start_ms: float, end_ms: float, modules: frozenset[str]
) -> dict[tuple[str, str], list[bytes]]:
    payloads: dict[tuple[str, str], list[bytes]] = defaultdict(list)
    for read in reads:
        payload = read.payload
        if (
            payload is not None
            and start_ms <= read.started_ms < end_ms
            and (not modules or read.module in modules)
        ):
            payloads[(read.module, read.did)].append(payload)
    return payloads
