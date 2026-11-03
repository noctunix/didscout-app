"""Command line entry point of didscout-logs."""

import argparse
import sys
from collections import Counter
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Final

from didscout_logs.experiments import (
    STEP_BEFORE,
    DidChange,
    diff_bytes,
    experiment_runs,
    run_changes,
)
from didscout_logs.failures import describe_read, find_bursts, group_failures
from didscout_logs.fit import Alias, fit_candidates, select_readings
from didscout_logs.series import DecodeSpec, did_series, parse_decode_spec
from didscout_logs.sessions import LogError, Session, load_sessions, session_created_ms
from didscout_logs.table import format_local, format_utc, render_table

_MS_PER_S: Final = 1000
_SHOWN_CHANGES: Final = 8

_FIT_EPILOG: Final = """\
Readings of older sessions may carry another quantity name than the
one they stand for: before the 2026-11-02 builds the predicted
charging power maximum was recorded as charge_power. --alias renames
readings for the fit, e.g.

  didscout-logs fit charge_power_max \\
      --alias charge_power=charge_power_max --before 2026-11-02

counts those old charge_power readings as charge_power_max (and no
longer as charge_power) in sessions created before 2026-11-02 UTC.
--before also takes a session id prefix: sessions created before that
session. Without --before an alias applies to every session.

SoC readings with source "confirmed" are always left out: they echo
the app's own estimate.
"""


def main(argv: Sequence[str] | None = None) -> int:
    """Run the command line tool.

    Args:
        argv: The arguments without the program name; None reads them
            from `sys.argv`.

    Returns:
        The process exit code: 0 on success, 1 on unusable logs.
    """
    args = _parser().parse_args(argv)
    try:
        lines = args.command(args)
    except LogError as err:
        sys.stderr.write(f"didscout-logs: {err}\n")
        return 1
    sys.stdout.write("".join(f"{line}\n" for line in lines))
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="didscout-logs", description="Analyse didscout-app recording logs offline."
    )
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument(
        "--logs",
        type=Path,
        default=None,
        help="directory with the buffer and marker files (default: logs/ in the "
        "enclosing Flutter project)",
    )
    common.add_argument(
        "--sessions",
        nargs="+",
        default=[],
        metavar="PREFIX",
        help="session id prefixes to analyse (default: every buffer)",
    )
    module_filter = argparse.ArgumentParser(add_help=False)
    module_filter.add_argument(
        "--module",
        action="append",
        default=[],
        dest="modules",
        help="only this module id; repeatable",
    )
    commands = parser.add_subparsers(required=True, metavar="COMMAND")

    fit = commands.add_parser(
        "fit",
        parents=[common, module_filter],
        help="fit display readings against every DID byte offset",
        description="Fit `value = a*x + b` for every DID, byte offset and u8/u16/s16 "
        "big-endian feature, interpolated between the samples bracketing each reading.",
        epilog=_FIT_EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    fit.add_argument("quantity", help="reading quantity, e.g. soc or battery_temp")
    fit.add_argument(
        "--max-gap",
        type=float,
        default=120.0,
        metavar="SECONDS",
        help="skip a reading whose bracketing samples are farther apart (default: 120)",
    )
    fit.add_argument("--top", type=int, default=20, help="candidates to print (default: 20)")
    fit.add_argument(
        "--min-n", type=int, default=10, help="fewest readings per candidate (default: 10)"
    )
    fit.add_argument(
        "--alias",
        action="append",
        default=[],
        type=_alias,
        metavar="RECORDED=MEANT",
        help="count readings recorded as RECORDED as MEANT; repeatable",
    )
    fit.add_argument(
        "--before",
        metavar="DATE|SESSION",
        help="apply the aliases only to sessions created before this UTC date/time or session",
    )
    fit.set_defaults(command=_run_fit)

    timeouts = commands.add_parser(
        "timeouts",
        parents=[common, module_filter],
        help="every non-ok read grouped by module, DID and transport",
    )
    timeouts.add_argument(
        "--transport",
        action="append",
        default=[],
        dest="transports",
        help="only this transport result, e.g. timeout; repeatable",
    )
    timeouts.add_argument(
        "--replies", type=int, default=3, help="distinct replies shown per group (default: 3)"
    )
    timeouts.set_defaults(command=_run_timeouts)

    bursts = commands.add_parser(
        "bursts",
        parents=[common],
        help="runs of consecutive writeFailed reads and what preceded them",
        description="List runs of consecutive writeFailed reads. For each run: the "
        "non-positive reads right before it (start relative to the run), the gap from "
        "the end of the previous read to the run, and the time until the next positive "
        "read.",
    )
    bursts.add_argument(
        "--min-length", type=int, default=10, help="shortest run reported (default: 10)"
    )
    bursts.add_argument(
        "--context",
        type=int,
        default=3,
        help="most preceding non-positive reads shown (default: 3)",
    )
    bursts.set_defaults(command=_run_bursts)

    experiments = commands.add_parser(
        "experiments",
        parents=[common, module_filter],
        help="DIDs whose payload changed across each experiment run",
        description="Compare each DID's last payload between the before and action "
        "steps with its first payload after the after step (and after an undo step, "
        "if recorded). The markers do not name the target ECUs, so every module read in "
        "both windows is compared; narrow it with --module. A DID marked ~ also changed "
        "within the before window on its own.",
    )
    experiments.set_defaults(command=_run_experiments)

    series = commands.add_parser(
        "series",
        parents=[common],
        help="a DID's positive payloads over time",
    )
    series.add_argument("module", help="module id, e.g. module6")
    series.add_argument("did", help="DID, e.g. 2AB8")
    series.add_argument(
        "--decode",
        type=_decode_spec,
        metavar="SPEC",
        help="decode <u|s><bits>@<offset>[*<scale>][<+|-><add>], big-endian, e.g. u16@0*0.125-40",
    )
    series.add_argument("--quantity", help="interleave readings of this quantity")
    series.add_argument(
        "--changes-only",
        action="store_true",
        help="show a payload only when it differs from the previous one",
    )
    series.set_defaults(command=_run_series)
    return parser


def _alias(text: str) -> Alias:
    recorded, separator, meant = text.partition("=")
    if not separator or not recorded or not meant:
        raise argparse.ArgumentTypeError(f"expected RECORDED=MEANT, got {text!r}")
    return Alias(recorded, meant, None)


def _decode_spec(text: str) -> DecodeSpec:
    try:
        return parse_decode_spec(text)
    except ValueError as err:
        raise argparse.ArgumentTypeError(str(err)) from err


def _logs_dir(args: argparse.Namespace) -> Path:
    if args.logs is not None:
        return Path(args.logs)
    cwd = Path.cwd()
    project = next((d for d in (cwd, *cwd.parents) if (d / "pubspec.yaml").is_file()), cwd)
    return project / "logs"


def _sessions(args: argparse.Namespace) -> list[Session]:
    return load_sessions(_logs_dir(args), args.sessions)


def _before_ms(args: argparse.Namespace) -> float | None:
    if args.before is None:
        return None
    try:
        moment = datetime.fromisoformat(args.before)
    except ValueError:
        return session_created_ms(_logs_dir(args), args.before)
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=UTC)
    return moment.timestamp() * _MS_PER_S


def _run_fit(args: argparse.Namespace) -> list[str]:
    sessions = _sessions(args)
    before_ms = _before_ms(args)
    aliases = [Alias(alias.recorded, alias.meant, before_ms) for alias in args.alias]
    readings = select_readings(sessions, args.quantity, aliases)
    candidates = fit_candidates(
        sessions,
        readings,
        max_gap_ms=args.max_gap * _MS_PER_S,
        min_n=args.min_n,
        modules=frozenset(args.modules),
    )
    summary = (
        f"{args.quantity}: {len(readings)} readings in "
        f"{len({reading.session_id for reading in readings})} sessions, "
        f"{len(candidates)} candidates"
    )
    rows = [
        [
            c.module,
            c.did,
            f"{c.feature}@{c.offset}",
            str(c.n),
            f"{c.line.r:.4f}",
            f"{c.line.slope:.6g}",
            f"{c.line.intercept:.6g}",
            f"{c.line.p90_error:.3g}",
            f"{c.line.max_error:.3g}",
        ]
        for c in candidates[: args.top]
    ]
    header = ["module", "DID", "feature", "n", "r", "a", "b", "p90", "max"]
    return [summary, "", *render_table(header, rows, right={3, 4, 5, 6, 7, 8})]


def _run_timeouts(args: argparse.Namespace) -> list[str]:
    groups = group_failures(_sessions(args), frozenset(args.modules), frozenset(args.transports))
    if not groups:
        return ["no failed reads"]
    reads: Counter[str] = Counter()
    dids: Counter[str] = Counter()
    for group in groups:
        reads[group.transport] += group.count
        dids[group.transport] += 1
    summary = [
        [transport, str(count), str(dids[transport])] for transport, count in reads.most_common()
    ]
    lines = [*render_table(["transport", "reads", "DIDs"], summary, right={1, 2}), ""]
    for group in groups:
        lines.append(
            f"{group.module} {group.did}  {group.transport}  "
            f"{group.count} reads in {group.sessions} sessions"
        )
        lines.extend(
            f"  {reply.count:>6}x  {reply.description}" for reply in group.replies[: args.replies]
        )
        if len(group.replies) > args.replies:
            lines.append(f"  ({len(group.replies) - args.replies} more distinct replies)")
    return lines


def _run_bursts(args: argparse.Namespace) -> list[str]:
    lines: list[str] = []
    for session in _sessions(args):
        for burst in find_bursts(session, min_length=args.min_length, context=args.context):
            first, last = burst.reads[0], burst.reads[-1]
            lines.append(
                f"{session.id[:8]}  {format_utc(first.started_ms)}  seq {first.sequence}"
                f"  {len(burst.reads)} writeFailed over "
                f"{_seconds(last.started_ms - first.started_ms)}"
                f"  gap {_seconds(burst.gap_ms)}  next positive {_seconds(burst.recovery_ms)}"
            )
            rows = [
                [
                    _seconds(read.started_ms - first.started_ms),
                    read.module,
                    read.did,
                    read.transport,
                    f"{read.duration_ns / 1e6:.0f} ms",
                    describe_read(read),
                ]
                for read in burst.preceding
            ]
            if not rows and burst.gap_ms is not None:
                lines.append("    the read right before was positive")
            if rows:
                lines.extend(
                    f"    {line}"
                    for line in render_table(
                        ["start", "module", "DID", "transport", "took", "reply"],
                        rows,
                        right={0, 4},
                    )
                )
            lines.append("")
    return lines or ["no bursts"]


def _run_experiments(args: argparse.Namespace) -> list[str]:
    lines: list[str] = []
    modules = frozenset(args.modules)
    for session in _sessions(args):
        for run in experiment_runs(session):
            steps = "  ".join(
                f"{step.step} {format_utc(step.at_ms)}"
                if step.step == STEP_BEFORE
                else f"{step.step} {format_utc(step.at_ms)[11:]}"
                for step in run.steps
            )
            lines.append(f"{session.id[:8]}  {run.experiment_id}  {steps}")
            changes = run_changes(session, run, modules)
            if changes is None:
                reason = run.cancel_reason
                lines.append(f"    no after reads{f' ({reason})' if reason else ''}")
            elif not changes:
                lines.append("    no DID changed")
            else:
                rows = [_change_row(session, change) for change in changes]
                lines.extend(
                    f"    {line}"
                    for line in render_table(["module", "DID", "before -> after", "undo"], rows)
                )
            lines.append("")
    return lines or ["no experiment runs"]


def _change_row(session: Session, change: DidChange) -> list[str]:
    header = session.request_headers.get(change.module)
    module = f"{change.module} ({header})" if header else change.module
    did = f"{change.did} ~" if change.moves_alone else change.did
    if change.undo is None:
        undo = ""
    elif change.undo == change.before:
        undo = "back"
    else:
        undo = _describe_diff(change.after, change.undo) or "same as after"
    return [module, did, _describe_diff(change.before, change.after), undo]


def _describe_diff(old: bytes, new: bytes) -> str:
    changes = diff_bytes(old, new)
    parts = [f"[{c.position}] {c.old:02X}->{c.new:02X}" for c in changes[:_SHOWN_CHANGES]]
    if len(changes) > _SHOWN_CHANGES:
        parts.append(f"(+{len(changes) - _SHOWN_CHANGES} more)")
    if len(old) != len(new):
        parts.append(f"length {len(old)}->{len(new)}")
    return " ".join(parts)


@dataclass(frozen=True, slots=True)
class _TimedRow:
    at_ms: float
    cells: list[str]


def _run_series(args: argparse.Namespace) -> list[str]:
    sessions = _sessions(args)
    points = did_series(sessions, args.module, args.did, changes_only=args.changes_only)
    spec: DecodeSpec | None = args.decode
    rows = [
        _TimedRow(
            point.at_ms,
            [*_when(point.session_id, point.at_ms), *_payload_cells(spec, point.payload)],
        )
        for point in points
    ]
    if args.quantity:
        series_sessions = {point.session_id for point in points}
        rows.extend(
            _TimedRow(
                reading.at_ms,
                [
                    *_when(reading.session_id, reading.at_ms),
                    *([f"{reading.value:g}"] if spec else []),
                    f"<- reading {reading.quantity} = {reading.value:g} ({reading.source})",
                ],
            )
            for session in sessions
            if session.id in series_sessions
            for reading in session.readings
            if reading.quantity == args.quantity
        )
    if not rows:
        return [f"no positive reads of {args.module} {args.did.upper()}"]
    rows.sort(key=lambda row: row.at_ms)
    header = ["local", "UTC", "session", *(["value"] if spec else []), "payload"]
    return render_table(header, [row.cells for row in rows], right={3} if spec else ())


def _when(session_id: str, at_ms: float) -> list[str]:
    return [format_local(at_ms), format_utc(at_ms), session_id[:8]]


def _payload_cells(spec: DecodeSpec | None, payload: bytes) -> list[str]:
    hex_payload = payload.hex(" ").upper()
    if spec is None:
        return [hex_payload]
    value = spec.decode(payload)
    return ["short" if value is None else f"{value:g}", hex_payload]


def _seconds(duration_ms: float | None) -> str:
    return "-" if duration_ms is None else f"{duration_ms / _MS_PER_S:.2f} s"
