# didscout-app

Android companion to `didscout`, the read-only OBD/UDS discovery CLI: one-tap vehicle
recording over a BLE OBD adapter (tested with an OBDLink CX), without a laptop in the car.

## Relation to didscout

`didscout` already defines what "read-only" means for this project; this app follows the
same rules rather than inventing its own. A recording produces a log in the same shape
`didscout record` does, so it can be fed into `didscout derive` and `didscout share` on a
computer afterwards - this app does not analyze or redact logs itself.

## Safety model

Every command sent to the adapter passes an allow-list before it leaves the device:

- UDS ReadDataByIdentifier (`0x22`) and mode-01 reads only, through the same allow-list
  approach as `didscout`.
- The VIN DIDs (`F190`, `F802`) are never read.
- No write, clear-DTC, routine-control, security-access, session-control, or reset
  service is reachable, regardless of what a profile or discovery result names.

## Planned features

- One-tap recording that can resume an interrupted session.
- Phase buttons (drive / charge / stand / park) to mark what the vehicle is doing while
  recording, without needing to type a note.
- Guided experiments: a prompted before/after capture around one action (e.g. a settings
  change), with the resulting diff shown on the phone.
- Sharing a recorded log so it can be fed into `didscout derive` on a computer.

## Status

Skeleton only - no BLE connection, no recording, no UI beyond a placeholder screen.

## License

AGPL-3.0-or-later. See `LICENSE`.
