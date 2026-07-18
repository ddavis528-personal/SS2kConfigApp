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
