"""Plain-text tables and timestamps for terminal output."""

from collections.abc import Collection, Sequence
from datetime import UTC, datetime


def render_table(
    header: Sequence[str], rows: Sequence[Sequence[str]], *, right: Collection[int] = ()
) -> list[str]:
    """Align rows of cells into columns separated by two spaces.

    Args:
        header: The column titles.
        rows: The cells, one sequence per row, as long as `header`.
        right: Indices of columns to right-align.

    Returns:
        The header line followed by one line per row, without trailing
        spaces.
    """
    widths = [max(len(row[i]) for row in [header, *rows]) for i in range(len(header))]
    return [
        "  ".join(
            cell.rjust(width) if index in right else cell.ljust(width)
            for index, (cell, width) in enumerate(zip(row, widths, strict=True))
        ).rstrip()
        for row in [header, *rows]
    ]


def format_utc(at_ms: float) -> str:
    """Format a Unix millisecond time as UTC with seconds.

    Args:
        at_ms: The time in Unix milliseconds.

    Returns:
        E.g. `2026-01-02 03:04:05Z`.
    """
    return datetime.fromtimestamp(at_ms / 1000, UTC).strftime("%Y-%m-%d %H:%M:%SZ")


def format_local(at_ms: float) -> str:
    """Format a Unix millisecond time in the local time zone.

    Args:
        at_ms: The time in Unix milliseconds.

    Returns:
        E.g. `2026-01-02 04:04:05.123 +0100`.
    """
    moment = datetime.fromtimestamp(at_ms / 1000, UTC).astimezone()
    millis = moment.microsecond // 1000
    return f"{moment:%Y-%m-%d %H:%M:%S}.{millis:03d} {moment:%z}"
