# didscout-app

Android companion to `didscout`, the read-only OBD/UDS discovery CLI: one-tap vehicle
recording over a BLE OBD adapter (tested with an OBDLink CX), without a laptop in the car.

## Relation to didscout

`didscout` already defines what "read-only" means for this project; this app follows the
same rules rather than inventing its own. A recording produces a log in the same shape
`didscout record` does, so it can be fed into `didscout derive` and `didscout share` on a
computer afterwards. `tool/log_analysis` fits the readings typed off the vehicle's displays
against every recorded DID and lists timeouts and experiment results; the app itself does
not redact logs.

## Safety model

Every command sent to the adapter passes an allow-list before it leaves the device:

- UDS ReadDataByIdentifier (`0x22`) and mode-01 reads only, through the same allow-list
  approach as `didscout`.
- The VIN DIDs (`F190`, `F802`) are never read.
- No write, clear-DTC, routine-control, security-access, session-control, or reset
  service is reachable, regardless of what a profile or discovery result names.

## Features

- One-tap recording that reconnects to the adapter after a dropped link.
- Phase buttons (drive / charge / stand / park) to mark what the vehicle is doing.
- Reading tiles for the values on the vehicle's displays, prefilled with the live value
  where the app decodes one, so a reading only needs a confirm or a correction.
- Discovery of answering ECUs and DIDs while recording, with the DIDs whose values move
  sampled more often.
- Guided experiments: the owner takes one action and undoes it, with the target ECUs'
  DIDs read before, after and after the undo, and the diff shown on the phone.
- Sharing a recorded log with its marker sidecar.

## Release build

An arm64-only signed release APK is built with `scripts/build-release-arm64.sh` (or the
"Release APK (arm64)" run configuration in Android Studio), which also installs it if
exactly one device is connected. One-time key setup is in `keystore.properties.example`.

## License

AGPL-3.0-or-later. See `LICENSE`.
