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
