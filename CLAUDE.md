# SmartSpin2k Config App — Session Context

## Project Overview

Flutter mobile app (iOS + Android) for configuring and controlling **SmartSpin2k** devices over BLE. SmartSpin2k is a DIY ESP32-based device that motorizes the resistance knob on any spin bike, turning it into a smart trainer compatible with Zwift, TrainerRoad, etc.

**Companion firmware repo:** `ddavis528-personal/smartspin2k`
**Current app version:** `1.2.6+61` (`pubspec.yaml`)
**Primary branch:** `develop`

---

## Repository Structure

```
lib/
  screens/
    scan_screen.dart          # Device discovery
    main_device_screen.dart   # Top-level device screen (tab host)
    shifter_screen.dart       # Virtual shifter + gear display  ← recent work
    workout_screen.dart       # Structured workout player
    power_table_screen.dart   # Power curve editor
    settings_screen.dart      # Device settings
    firmware_update_screen.dart
    ble_log_screen.dart
  utils/
    bledata.dart              # Core BLE state manager (BLEData / BLEDataManager)  ← recent work
    constants.dart            # All vName string constants
    bleConstants.dart         # BLE UUIDs and characteristic constants
    bleOTA.dart               # BLE firmware OTA
    wifi_ota.dart             # WiFi firmware OTA
    ftmsControlPoint.dart     # FTMS control point encoding
    power_table_management.dart
    presets.dart
    workout/                  # Workout controller + parsers
    theme_provider.dart
  widgets/
    device_header.dart        # Device status bar (RSSI, FW version, reconnect)  ← recent work
    ss2k_app_bar.dart
    metric_card.dart
    power_table_chart.dart
```

---

## Key BLE Architecture

### BLEData / BLEDataManager (`lib/utils/bledata.dart`)
- `BLEDataManager.forDevice(device)` returns the singleton `BLEData` for a device.
- `setupConnection(device)` → `_discoverServices()` → `_findChar()` → sets `_myCharacteristic` and starts `_notifySubscription`.
- `_findChar()` is guarded by `_findCharCompleter` to prevent concurrent calls replacing `_myCharacteristic` while a subscription is live.
- `getMyCharacteristic(device)` is a **pure lookup** — it does NOT fire `_findChar()` as a side effect (that race was fixed; see changelog).
- `characteristicChanges` stream: decoded BLE indications from the device flow here; screens subscribe to this.
- `requestSetting(device, vName)` writes a read-request packet; the response arrives on `characteristicChanges`.
- `writeToSS2k(device, entry)` encodes and writes a setting to the device.
- Custom characteristic uses **indicate** (acknowledged), not notify. Flutter Blue Plus `setNotifyValue(true)` enables both; `onValueReceived` receives both.

### Shifter flow
1. App calls `bleData.writeToSS2k(device, {vName: shifterPositionVname, value: N})`.
2. Firmware's `FTMSModeShiftModifier()` detects the delta and sends a BLE indication back.
3. `characteristicChanges` emits a `shifterPositionVname` event; `shifter_screen.dart` calls `_syncShifterValueFromCache()` to confirm the new gear.
4. A 1-second timeout (`_pendingShiftTimer`) reverts optimistic UI if no confirmation arrives.

### hMin / hMax / shiftStep sentinels
- Before homing: `hMin = hMax = INT32_MIN` (-2147483648). The guard for "not yet homed" is `hMax <= hMin` (not `== 0`).
- After homing: `minStep = 0`, `maxStep = hMax`.
- Max gear = `(hMax - hMin) / shiftStep` (rounded).

---

## Recent Changes (as of 2026-07-18)

### WiFi OTA overhaul (1.2.6+61)
- **iOS**: `Info.plist` now declares `NSLocalNetworkUsageDescription`, `NSBonjourServices` (`_http._tcp`), and `NSAppTransportSecurity → NSAllowsLocalNetworking`. Without these, iOS 14+ silently blocked all local-network traffic and WiFi OTA could never succeed (always fell back to BLE). iOS prompts for Local Network permission on first use.
- `wifi_ota.dart`: skips in-app `MDnsClient` on iOS (needs a multicast entitlement the app doesn't hold); iOS resolves `.local` natively. Accepts optional `manualIp` tried as the first candidate. Progress loop completes when the device responds instead of a fixed ~36 s animation. Reachability timeout 15 s → 6 s per candidate.
- `firmware_update_screen.dart`: manual "Device IP for WiFi update" field (persisted via `SharedPreferences`, key `wifiOtaManualIp`); device name falls back from `advName` (empty on direct reconnect) to `platformName`.

### `lib/screens/shifter_screen.dart`
- Added `_maxGearNotifier` + `_computeMaxGear()`: shows `gear/maxGear` (e.g. `8/16`) in the gear display; shows `?` until homing data arrives.
- `_computeMaxGear()` guard: `hMax <= hMin` (catches INT32_MIN sentinel; old guard `hMax == 0 && hMin == 0` failed).
- `shift(amount)`: floors gear writes at `0` — pressing down at gear 0 returns early instead of sending `-1` to firmware (which caused motor to drive to max resistance).
- `initState` now calls `bleData.requestSetting(device, shiftStepVname)` to seed the max-gear calculation.
- `_characteristicChangeSubscription` updates `_maxGearNotifier` when `BLE_hMaxVname`, `BLE_hMinVname`, or `shiftStepVname` change.

### `lib/utils/bledata.dart`
- Added `_findCharCompleter` guard to `_findChar()` to prevent concurrent calls.
- Removed fire-and-forget `_findChar()` side effect from `getMyCharacteristic()`.

### `lib/widgets/device_header.dart`
- Removed direct `device.discoverServices()` call from `_refreshDeviceInfo()` — it bypassed `_discoverServicesCompleter` and replaced characteristic instances while `_notifySubscription` was still attached to the old ones, silently killing incoming notifications.

---

## Bug History and Current Status

### Issue 1: Gear number not updating in app / virtual shifter unreliable
**Symptoms (reported):** Gear number in the app didn't change when shifting from the device's physical buttons. Virtual shifter buttons in the app worked inconsistently — sometimes the gear display updated briefly then reverted, sometimes it didn't respond at all.

**Root cause diagnosed:** Two interacting BLE subscription races:
1. `getMyCharacteristic()` was fire-and-forgetting `_findChar()` on every call. This periodically replaced `_myCharacteristic` with a newly-discovered instance while `_notifySubscription` was still attached to the old one, silently killing all incoming BLE indications.
2. `device_header.dart`'s `_refreshDeviceInfo()` was calling `device.discoverServices()` directly, bypassing the `_discoverServicesCompleter` lock and causing the same stale-characteristic problem on reconnect.

**Fixes applied:** `bledata.dart` `_findCharCompleter` guard + removed side-effect from `getMyCharacteristic()`; `device_header.dart` direct `discoverServices()` call removed.

**Status after fix:** Physical shifter reliably updates the app gear display. Virtual buttons work after the device has been calibrated (first pedal stroke).

---

### Issue 2: Virtual shifter underflow — motor drives to max resistance
**Symptoms (reported, after Issue 1 fix):** Pressing the down button on the virtual shifter at gear 0 caused the motor to drive toward (and sometimes beyond) maximum resistance. This happened before calibration. After the first calibration (pedaling), virtual buttons worked but underflow still occurred at gear 0.

**Root cause:** `shift(-1)` computed `next = 0 + (-1) = -1` and wrote `-1` to the firmware. The firmware's `bytes_to_u16` decoded this as a large positive number, bypassing the bounds check in `FTMSModeShiftModifier()`.

**Fix applied:** Added `if (next < 0) return;` in `shift()` before writing to the device (`shifter_screen.dart:185`).

**Status: FIXED, NOT YET TESTED ON HARDWARE.** Build `ae7eb4a` is on `develop` and CI passed; no physical device test has been done.

---

### Issue 3: Max gear denominator always showing "0"
**Symptoms (reported, after Issue 1 fix):** The gear display showed `8/0` (or similar) instead of `8/16`. The denominator was always 0, even after calibration.

**Root cause:** `_computeMaxGear()` guarded with `(hMax == 0 && hMin == 0)` to detect "not yet homed". But the firmware uses `INT32_MIN` (-2147483648) as the sentinel before homing, not 0. So `INT32_MIN - INT32_MIN = 0`, which divided by `shiftStep` returned `"0"` instead of `"?"`.

**Fix applied:** Changed guard in `_computeMaxGear()` from `(hMax == 0 && hMin == 0)` to `hMax <= hMin` (`shifter_screen.dart:94`).

**Status: FIXED, NOT YET TESTED ON HARDWARE.** Same build as Issue 2.

---

### Issue 4: Virtual buttons don't work before calibration
**Symptoms:** Before the first pedal stroke (homing not triggered), virtual shifter button presses showed a brief optimistic gear change then immediately reverted. Motor did not move.

**Root cause:** Expected firmware behavior — `FTMSModeShiftModifier()` is gated by `spinDownFlag == 0`. Before homing, `spinDownFlag != 0`, so gear writes are accepted but not executed. The 1-second `_pendingShiftTimer` in the app times out and reverts the optimistic display. After homing (first pedal stroke), this resolves itself.

**Status:** Not a bug. No fix needed, but a UI indicator for "waiting for calibration" would improve UX.

---

## Potential Next Steps

- **Verify Issues 2 & 3 on hardware** — underflow floor and `hMax <= hMin` guard are both in the current build but untested on a physical device.
- **Gear ceiling cap in `shift()`**: App floors at 0 but doesn't cap at `maxGear`. Firmware enforces the ceiling, so cosmetic — but a symmetric app-side cap (`if (next > maxGear) return;`) would give cleaner UX and prevent brief optimistic overshoots.
- **Request hMin/hMax on screen open**: `shifter_screen.dart` requests `shiftStepVname` on init but not `BLE_hMinVname`/`BLE_hMaxVname`. Requesting all three would populate max gear faster on first open.
- **Calibration status indicator**: Show a visual hint when `spinDownFlag != 0` so the user knows to start pedaling before virtual shifting will work.
- **Dial/progress visualization**: Replace `N/M` text with a visual arc or progress bar from min to max resistance.

### CI / Build
- GitHub Actions workflow: `Build and Release Applications` triggers on push to `develop`.
- Build artifacts are APK + IPA released to GitHub Releases automatically.
- Check run status via the Actions tab on `ddavis528-personal/ss2kconfigapp`.

---

## Development Workflow

```bash
# Clone and set up
git clone https://github.com/ddavis528-personal/ss2kconfigapp
cd ss2kconfigapp
git checkout develop
flutter pub get

# Run on device
flutter run

# Build
flutter build apk
flutter build ios

# Push to trigger CI build
git push origin develop
```

**Branch convention:** Development happens directly on `develop`; CI builds and releases on every push to `develop`.
