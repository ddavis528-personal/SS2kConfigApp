# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

### Added

### Changed
