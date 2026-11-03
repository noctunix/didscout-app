# didscout-logs

Offline analysis of the app's recording logs: the buffer `<session>.jsonl`
and its marker sidecar `<session>.jsonl.markers.jsonl`. Read-only; it never
writes into the logs directory.

## Setup

Needs [uv](https://docs.astral.sh/uv/) and Python 3.12 or newer.

```sh
cd tool/log_analysis
uv sync
```

## Usage

Run from anywhere inside the Flutter project: by default the tool reads
`logs/` next to the enclosing `pubspec.yaml`. `--logs DIR` points elsewhere,
`--sessions PREFIX...` picks sessions by id prefix (default: all).
`uv run didscout-logs <command> --help` lists every option.

```sh
# Rank every DID byte offset (u8, u16, s16 big-endian) by how well a line
# value = a*x + b reproduces the typed display readings.
uv run didscout-logs fit soc
uv run didscout-logs fit battery_temp --module bms --max-gap 300 --min-n 5

# Old sessions recorded the predicted maximum as charge_power.
uv run didscout-logs fit charge_power_max \
    --alias charge_power=charge_power_max --before 2026-11-02

# Every non-ok read by module, DID and transport, with the reply decoded.
uv run didscout-logs timeouts --transport timeout

# Runs of >= 10 consecutive writeFailed reads and what came right before.
uv run didscout-logs bursts --sessions 0123abcd

# Per experiment run: DIDs whose payload changed from before to after.
uv run didscout-logs experiments --module climate

# One DID over time, decoded, with the owner's readings interleaved.
uv run didscout-logs series bms 1E10 --decode 'u16@0*0.125-40' \
    --quantity battery_temp --changes-only
```

### How the commands decide

- **fit**: each reading is paired with the two positive samples of a DID
  that bracket it in time within its session (reply time), and every
  feature is interpolated linearly between them. Pairs farther apart than
  `--max-gap` seconds (default 120) are skipped. Candidates need `--min-n`
  readings (default 10) and are ranked by the 90th-percentile absolute
  error (nearest rank), then the maximum. SoC readings with source
  `confirmed` are left out.
- **timeouts**: replies are reassembled from the ISO-TP frames and decoded
  into positive, final NRC, responsePending without a final answer,
  incomplete, `NO DATA`, empty or unrecognized.
- **bursts**: shows the non-positive reads right before each run (start
  relative to the run), the gap from the end of the previous read, and the
  time until the next positive read.
- **experiments**: compares each DID's last payload between the `before`
  and the following step with its first payload after `after` (and after
  `undone`, if recorded; the window between `undo` and `undone` is when
  the owner takes the action back and is left out). The markers do not name the target ECUs, so every
  module read in both windows is listed; `~` marks a DID that changed
  within the before window on its own.
- **series** `--decode` takes `<u|s><bits>@<offset>[*<scale>][<+|-><add>]`,
  big-endian, bits 8/16/24/32.

## Checks

```sh
scripts/check.sh
```

Tests use synthetic fixtures built in `tests/synthetic.py`; real captures
never go into the repository.
