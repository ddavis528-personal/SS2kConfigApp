# SmartSpin2k Config App — Session Context

## Project Overview

Flutter mobile app (iOS + Android) for configuring and controlling **SmartSpin2k** devices over BLE. SmartSpin2k is a DIY ESP32-based device that motorizes the resistance knob on any spin bike, turning it into a smart trainer compatible with Zwift, TrainerRoad, etc.

**Companion firmware repo:** `ddavis528-personal/smartspin2k`
**Current app version:** `1.2.5+60` (`pubspec.yaml`)
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

## Known Issues / Next Steps

### Potential improvements
- **Gear ceiling check in `shift()`**: Currently only floors at 0. If desired, could also cap at `maxGear` so pressing up past max is a no-op (symmetric with the floor). Currently the firmware caps it, so this is cosmetic.
- **Max gear display before homing**: Shows `?` until the device has been homed. Could show a prompt or explanation in the UI.
- **Dial/progress visualization**: The gear display currently shows `N/M` text. A future enhancement would be a visual arc or progress indicator from min to max resistance.
- **`requestSetting` for hMin/hMax on screen open**: `shifter_screen.dart` already requests `shiftStepVname` on init; it could also explicitly request `BLE_hMinVname` and `BLE_hMaxVname` to populate max gear faster on first open.

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
