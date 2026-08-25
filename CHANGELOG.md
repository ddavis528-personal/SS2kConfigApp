# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each versioned section below matches the `version:` field in `pubspec.yaml` at
the time of that release, so every GitHub release gets its own unique tag
instead of silently overwriting a previous one.

## [Unreleased]

### Fixed

### Added

### Changed

## [1.2.10+65] - 2026-08-01

### Fixed
- **Max-gear denominator and the range-trim controls no longer stay stuck when the device already knows its limits.** The screen asked for hMin/hMax/shiftStep once when it opened, which can happen before BLE service discovery has produced a writable characteristic; that request is then silently dropped and nothing ever asked again, so the denominator stayed `?` and the "Fine-tune gear range" buttons stayed greyed out for the whole session. The request is now retried until the values arrive, and re-sent on reconnect.
- **The coupler-slip warning no longer sits on top of the metric cards and the up-shift button.** It was a `Positioned` overlay pinned to the top of the screen; it is now part of the layout so it occupies its own space.
- When the range-trim sheet is unavailable because the device has never been calibrated, it now says so and explains that pedaling starts calibration, instead of only greying the buttons out.

## [1.2.9+64] - 2026-08-01

### Added
- **Cadence Correction Factor** setting (advanced), for bikes that report a lower cadence than you are actually pedaling — which makes workout RPM targets impossible to reach. Set it to the ratio between real and reported cadence (e.g. 1.2 if the app shows 75 when you are really at 90). The firmware applies it to every cadence reading, so it also corrects the RPM sent to Zwift. Changing it resets the power table's confidence, since that table is keyed by cadence.

## [1.2.8+63] - 2026-08-01

### Added
- **Fine-tune the gear range from the shifter screen.** A new tune button opens a sheet that trims the lowest and highest gear a gear at a time ("Easier" / "Harder" rather than raw step counts, which mean nothing to most people). Writes the device's hMin/hMax directly, and the firmware persists them. Guards: at least 3 gears of range is always kept, the lower limit cannot be trimmed below the calibrated floor (that margin is what keeps the knob off the low mechanical stop), and the whole sheet is unavailable during calibration, which overwrites both limits when it completes.
- **Coupler-slip warning.** When the firmware reports that gear changes have stopped affecting power in mid travel — meaning the position counter probably no longer matches the knob — the shifter screen shows an advisory banner recommending recalibration. The device keeps working; this informs rather than blocks, and a successful calibration clears it.
- Power Scale Factor (K) is now readable in the app's advanced settings, so you can see whether the firmware's high-end power model is actually training (it rises above 1.0 as the device learns that the pad saturates near the top of travel).

### Changed
- **Virtual shift buttons are now visibly disabled during calibration** instead of looking active and silently ignoring presses. They were already ignored, but the button still animated on tap, which read as the app being broken rather than the control being unavailable.

## [1.2.7+62] - 2026-08-01

### Fixed
- **Max-gear denominator no longer stuck on `?`.** The shifter screen only requested `shiftStep` on open and relied on the firmware notifying hMin/hMax. The firmware only notifies those on *change*, and the change happens at boot — before any app is connected — so an app that connected later never learned the travel limits and the denominator never appeared. The screen now explicitly requests hMin, hMax and shiftStep when it opens, and re-requests them when a calibration run finishes (which is when those values change).

### Added
- **"Calibrating…" status on the virtual shifter screen.** While the device is calibrating, the gear number is replaced with a spinner and status text instead of a number that jumps around meaninglessly: "Calibrating…" (or "Retrying calibration…" after a failed attempt), plus "Pedal to begin" while the run is waiting on you, and always the reminder that holding either shifter button for 5 seconds cancels. Driven by the firmware's new calibration-status characteristic (`0x2F`).
- Virtual shift buttons are ignored while calibration is in progress. The firmware queues gear writes during calibration rather than executing them, so a press previously showed an optimistic gear change that silently reverted a second later — and it also cancelled the in-progress homing sweep.

### Changed

## [1.2.6+61] - 2026-07-18

### Fixed
- **WiFi firmware updates now possible on iOS**: `Info.plist` was missing `NSLocalNetworkUsageDescription`, `NSBonjourServices`, and an App Transport Security exception for local networking, so iOS 14+ silently blocked both mDNS discovery and plain-HTTP uploads to the device — the update always "fell back to Bluetooth". The keys are now declared; iOS will prompt for Local Network permission on the first WiFi update attempt.
- WiFi OTA no longer attempts in-app mDNS resolution on iOS (it requires a multicast entitlement the app does not hold and always failed); iOS resolves the device's `.local` hostname natively once local-network permission is granted.
- WiFi OTA used `device.advName`, which is empty when the app reconnects without a fresh scan, producing unreachable URLs like `http://.local`; it now falls back to `platformName`.
- WiFi OTA progress bar no longer runs a fixed ~36-second animation regardless of transfer state; it now completes as soon as the device confirms the flash.
- Reduced per-candidate reachability timeout from 15 s to 6 s so a genuine WiFi failure falls back to Bluetooth in seconds instead of ~45 s.
- Fixed virtual shifter "shift down" sending gear -1 (and beyond) when already at gear 0, which caused the motor to drive toward maximum resistance; the app now floors gear writes at 0.
- Fixed max-gear denominator always showing `0` on un-homed devices: the guard now checks `hMax <= hMin` instead of `hMax == 0 && hMin == 0`, correctly catching the INT32_MIN sentinel the firmware uses before the first homing run.

### Added
- Optional "Device IP for WiFi update" field on the firmware update screen. When set (find the IP on the SmartSpin2k web page), it is tried before mDNS/hostname discovery, making WiFi updates reliable on networks where `.local` resolution doesn't work. The value is remembered across app restarts.

### Changed
- Shifter screen now displays current gear as `gear/maxGear` (e.g. `8/16`) so the resistance ceiling is always visible. Max gear is derived live from the device's hMin, hMax, and shiftStep values; shows `?` until homing data arrives.

## [1.2.5+60] - 2026-06-28

### Fixed
- Fixed `FirmwareUpdateScreen._initialize()` unconditionally accessing the `late` fields `firmwareDataCharacteristic`/`firmwareControlCharacteristic` (guarded only by `isSimulated`), even though they're only assigned when `configAppCompatibleFirmware` is true; opening the screen on a device without BLE-OTA-compatible firmware threw a `LateInitializationError`. Now also gated on `configAppCompatibleFirmware`.
- Fixed an out-of-bounds `RangeError` risk in the `powerTableData` decode loop in `bledata.dart`, which read 16-bit values without checking that a full 2-byte pair remained in the buffer.

### Added

### Changed

## [1.2.4+59] - 2026-06-28

### Fixed
- Fixed `getMyCharacteristic()` returning an uninitialized `late` field (causing a `LateInitializationError`) when no matching characteristic was found; it now returns nullable, and callers null-check before writing or decoding.
- Fixed `writeToSS2k()` encoding "long"-typed settings with base-32 (`toRadixString(32)`) instead of hex (`toRadixString(16)`), which silently corrupted every "long"-typed setting write.
- Fixed the power table write using `Uint16List.fromList` with negative values, which threw a `RangeError`; switched to `Int16List`.
- Fixed the firmware-update upload not awaiting the actual HTTP response — progress was reported on a timer regardless of whether the upload succeeded; it now awaits the response and checks for `statusCode == 200`.
- Fixed a leaked `Timer.periodic` in the firmware update screen by making it lazily created instead of eagerly started.
- Fixed both OTA button handlers firing-and-forgetting `startFirmwareUpdate()` instead of awaiting it.
- Added a `mounted` guard before popping the navigator after firmware update, to avoid use-after-dispose.
- Fixed `progressTimer` never being cancelled in `WorkoutController.dispose()`, leaking a periodic timer per workout session.
- `clearDataForDevice()` now disposes notifiers before removal; `dispose()` now closes `_logStreamController`.
- Fixed "Choose Firmware From Dialog" failing with "device disconnected before the upload could complete" whenever the BLE fallback path was used: `Esp32OtaPackage.updateFirmware()` ignored the already-selected `binFilePath` for picker-sourced firmware and re-opened the system file picker a second time mid-update. It now reads the previously-resolved file directly, like the URL/release flow.

### Added

### Changed
