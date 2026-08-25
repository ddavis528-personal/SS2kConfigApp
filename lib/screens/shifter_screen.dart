/*
 * Copyright (C) 2020  Anthony Doud
 * All rights reserved
 *
 * SPDX-License-Identifier: GPL-2.0-only
 */
import 'dart:async';
import 'package:ss2kconfigapp/utils/constants.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../utils/bledata.dart';
import '../widgets/metric_card.dart';
import '../widgets/ss2k_app_bar.dart';
import '../widgets/power_table_chart.dart';

class ShifterScreen extends StatefulWidget {
  final BluetoothDevice device;
  const ShifterScreen({Key? key, required this.device}) : super(key: key);

  @override
  State<ShifterScreen> createState() => _ShifterScreenState();
}

class _ShifterScreenState extends State<ShifterScreen> {
  late BLEData bleData;
  late ValueNotifier<String> t;
  late ValueNotifier<String> _maxGearNotifier;
  late ValueNotifier<int> _calibrationStateNotifier;
  Map<String, dynamic> c = const {};
  Timer? _refreshTimer;
  Timer? _pendingShiftTimer;
  String? _confirmedShifterValue;
  String? _pendingShifterValue;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  StreamSubscription<CharacteristicChangeEvent>? _characteristicChangeSubscription;
  double _chartOpacity = 0.15;
  bool _showOpacityControl = false;
  // Never let manual trimming squeeze the range below this many gears.
  static const int _minTrimGears = 3;
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  final GlobalKey<PowerTableChartState> _chartKey = GlobalKey<PowerTableChartState>();

  @override
  void initState() {
    super.initState();
    // Keep the shifter screen awake during use, matching workout behavior.
    WakelockPlus.enable();
    bleData = BLEDataManager.forDevice(this.widget.device);
    t = ValueNotifier("Connecting");
    _maxGearNotifier = ValueNotifier(_computeMaxGear());
    _calibrationStateNotifier = ValueNotifier(_readCalibrationState());
    _syncShifterValueFromCache();

    //special setup for demo mode
    if (bleData.isSimulated) {
      t.value = "0";
      return;
    }

    if (t.value == "Connecting") {
      _requestShifterPosition();
    }
    _requestGearRange();

    _refreshTimer = Timer.periodic(const Duration(seconds: 15), (refreshTimer) {
      if (!mounted) {
        refreshTimer.cancel();
        return;
      }
      // Reconnection is handled centrally by BLEData.startConnectionMonitor.
      // This timer only needs to re-request the shifter position if still pending.
      if (this.widget.device.isConnected && t.value == "Connecting") {
        _requestShifterPosition();
      }
      // Keep asking for the travel limits until they arrive. The initial request can be sent
      // before service discovery has produced a writable characteristic, in which case it is
      // silently dropped - which left the gear denominator stuck on "?" and the range trim
      // sheet permanently greyed out even though the device knew its limits.
      if (this.widget.device.isConnected && _maxGearNotifier.value == "?") {
        _requestGearRange();
      }
    });

    //Start Subscription
    rwSubscription();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _pendingShiftTimer?.cancel();
    _connectionStateSubscription?.cancel();
    _characteristicChangeSubscription?.cancel();
    t.dispose();
    _maxGearNotifier.dispose();
    _calibrationStateNotifier.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  /// Asks the device for everything the gear display and range trim need. All of it must be
  /// requested rather than waited for: the firmware notifies hMin/hMax only when they *change*,
  /// and that happens at boot, before any app is connected.
  void _requestGearRange() {
    bleData.requestSetting(widget.device, shiftStepVname);
    bleData.requestSetting(widget.device, BLE_hMinVname);
    bleData.requestSetting(widget.device, BLE_hMaxVname);
    bleData.requestSetting(widget.device, calibrationStateVname);
  }

  int _readCalibrationState() {
    return int.tryParse(bleData.getVnameValue(calibrationStateVname)) ?? CalibrationState.idle;
  }

  int _readInt(String vName) => int.tryParse(bleData.getVnameValue(vName)) ?? 0;

  /// Nudges a travel limit by one gear and writes it to the device.
  ///
  /// [vName] is BLE_hMinVname or BLE_hMaxVname; [gears] is +1/-1. Guards keep at least
  /// [_minTrimGears] of usable range so the limits can never cross or collapse, and block edits
  /// while calibration is running (it overwrites both limits when it finishes).
  Future<void> _trimLimit(String vName, int gears) async {
    if (CalibrationState.isBusy(_calibrationStateNotifier.value)) return;

    final shiftStep = _readInt(shiftStepVname);
    final hMin = _readInt(BLE_hMinVname);
    final hMax = _readInt(BLE_hMaxVname);
    if (shiftStep <= 0 || hMax <= hMin) {
      _showTrimMessage("Calibrate the device before trimming its range.");
      return;
    }

    int newMin = hMin;
    int newMax = hMax;
    if (vName == BLE_hMinVname) {
      newMin = hMin + (gears * shiftStep);
      // Calibration always establishes the floor at 0, leaving a gear of physical backoff below
      // it. Going lower would spend that margin and drive toward the low mechanical stop, which
      // is the grinding we just designed out — trim inward only.
      if (newMin < 0) {
        _showTrimMessage("Already at the calibrated lower limit.");
        return;
      }
    } else {
      newMax = hMax + (gears * shiftStep);
    }

    if ((newMax - newMin) < (_minTrimGears * shiftStep)) {
      _showTrimMessage("Keep at least $_minTrimGears gears of range.");
      return;
    }

    final entry = bleData.customCharacteristic.firstWhere(
      (c) => c["vName"] == vName,
      orElse: () => <String, dynamic>{},
    );
    if (entry.isEmpty) return;

    final newValue = (vName == BLE_hMinVname) ? newMin : newMax;
    entry["value"] = newValue.toString();
    bleData.writeToSS2k(widget.device, entry, s: newValue.toString());
    // Read back so the display reflects what the device actually accepted rather than what we
    // asked for. The firmware persists hMin/hMax itself when they change.
    await Future.delayed(const Duration(milliseconds: 250));
    await bleData.requestSetting(widget.device, vName);
    if (mounted) {
      _maxGearNotifier.value = _computeMaxGear();
    }
  }

  void _showTrimMessage(String message) {
    _scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  String _computeMaxGear() {
    final hMax = int.tryParse(bleData.getVnameValue(BLE_hMaxVname)) ?? 0;
    final hMin = int.tryParse(bleData.getVnameValue(BLE_hMinVname)) ?? 0;
    final shiftStep = int.tryParse(bleData.getVnameValue(shiftStepVname)) ?? 0;
    if (shiftStep <= 0 || hMax <= hMin) return "?";
    return ((hMax - hMin) / shiftStep).round().toString();
  }

  bool _isValidShifterValue(String value) {
    return value.isNotEmpty && value != "null" && value != noFirmSupport;
  }

  void _syncShifterValueFromCache() {
    c = this.bleData.customCharacteristic.firstWhere(
      (i) => i["vName"] == shifterPositionVname,
      orElse: () => <String, dynamic>{},
    );

    final shifterValue = c["value"]?.toString() ?? "";
    if (_isValidShifterValue(shifterValue)) {
      _confirmedShifterValue = shifterValue;
      if (_pendingShifterValue != null) {
        _pendingShiftTimer?.cancel();
        _pendingShiftTimer = null;
        _pendingShifterValue = null;
      }
      t.value = shifterValue;
    } else {
      t.value = "Connecting";
    }
  }

  void _requestShifterPosition() {
    if (!widget.device.isConnected || t.value != "Connecting") {
      return;
    }
    bleData.requestSetting(widget.device, shifterPositionVname);
  }

  Future rwSubscription() async {
    _connectionStateSubscription = this.widget.device.connectionState.listen((state) async {
      if (state == BluetoothConnectionState.connected) {
        // After a reconnection the cached gear value is stale.
        // Reset to "Connecting" so _requestShifterPosition re-fetches
        // from the device and the UI shows a loading state until the
        // authoritative value arrives via characteristicChanges.
        _confirmedShifterValue = null;
        _pendingShifterValue = null;
        _pendingShiftTimer?.cancel();
        t.value = "Connecting";
        _requestShifterPosition();
        _requestGearRange();
      }
    });

    _characteristicChangeSubscription = bleData.characteristicChanges.listen((event) {
      if (!mounted) return;

      // Shifter position from device is authoritative (includes external shifter and accepted app shifts).
      if (event.vName == shifterPositionVname) {
        _syncShifterValueFromCache();
      }

      if (event.vName == BLE_hMaxVname || event.vName == BLE_hMinVname || event.vName == shiftStepVname) {
        _maxGearNotifier.value = _computeMaxGear();
      }

      if (event.vName == calibrationStateVname) {
        final previous = _calibrationStateNotifier.value;
        final current = _readCalibrationState();
        _calibrationStateNotifier.value = current;
        // Calibration establishes the travel limits, so refresh the gear range when it ends.
        if (CalibrationState.isBusy(previous) && !CalibrationState.isBusy(current)) {
          bleData.requestSetting(widget.device, BLE_hMinVname);
          bleData.requestSetting(widget.device, BLE_hMaxVname);
          _requestShifterPosition();
        }
      }

      // Keep simulated watts in sync with FTMS mode, matching the live updates used by the power table chart
      if (bleData.FTMSmode == 0 || bleData.simulateTargetWatts == false) {
        bleData.simulatedTargetWatts = "";
      }
    });
  }

  void _startPendingShiftTimeout() {
    _pendingShiftTimer?.cancel();
    _pendingShiftTimer = Timer(const Duration(milliseconds: 1000), () {
      if (!mounted || _pendingShifterValue == null) {
        return;
      }

      _pendingShifterValue = null;
      t.value = _confirmedShifterValue ?? "Connecting";
    });
  }

  shift(int amount) {
    if (_pendingShifterValue != null) {
      return;
    }

    // During calibration the firmware queues gear writes instead of executing them (and a
    // shifter-position change cancels the in-progress homing sweep), so the optimistic update
    // would just flicker and revert. Ignore the press and keep showing calibration status.
    if (CalibrationState.isBusy(_calibrationStateNotifier.value)) {
      return;
    }

    if (t.value != "Connecting") {
      final current = int.tryParse(_confirmedShifterValue ?? t.value);
      if (current == null) {
        return;
      }
      final next = current + amount;
      if (next < 0) return;
      final _t = next.toString();
      c = Map<String, Object>.from(c)..["value"] = _t;
      this.bleData.writeToSS2k(this.widget.device, c);
      _pendingShifterValue = _t;
      t.value = _t;
      _startPendingShiftTimeout();
    }

    WakelockPlus.enable();
  }

  /// A null [onPressed] renders Flutter's disabled style and drops the tap ripple, so a button
  /// that can't do anything looks that way instead of giving feedback and silently ignoring the
  /// press (which is how it read during calibration).
  Widget _buildShiftButton(IconData icon, VoidCallback? onPressed, {double height = 150}) {
    return SizedBox(
      height: height,
      width: height * 0.8,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          elevation: 5,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(height * 0.15))),
          padding: EdgeInsets.zero,
        ),
        child: Icon(icon, size: height * 0.4),
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildGearDisplay(String gearNumber, {double fontSize = 48}) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: fontSize * 0.3, horizontal: fontSize * 0.6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(fontSize * 0.3),
      ),
      child: Text(
        gearNumber,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// Replaces the gear number while the device is calibrating. Includes the abort gesture so
  /// the user is never stuck watching a run they want to stop.
  Widget _buildCalibrationDisplay(int calibrationState, {double fontSize = 48}) {
    final String heading = calibrationState == CalibrationState.retry ? "Retrying calibration…" : "Calibrating…";
    final String detail = calibrationState == CalibrationState.pending
        ? "Pedal to begin. Hold either shifter button 5s to cancel."
        : "Hold either shifter button 5s to cancel.";
    final double headingSize = fontSize * 0.45;

    return Container(
      padding: EdgeInsets.symmetric(vertical: fontSize * 0.3, horizontal: fontSize * 0.5),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(fontSize * 0.3),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: headingSize,
            height: headingSize,
            child: CircularProgressIndicator(strokeWidth: headingSize * 0.12),
          ),
          SizedBox(height: fontSize * 0.25),
          Text(
            heading,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: headingSize,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          SizedBox(height: fontSize * 0.15),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: fontSize * 6),
            child: Text(
              detail,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: headingSize * 0.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Bottom sheet for fine-tuning the calibrated travel limits a gear at a time.
  ///
  /// "Easier"/"Harder" rather than raw step counts: the user is trimming how far the knob is
  /// allowed to turn, and the numbers underneath are meaningless to most people. Rebuilt on
  /// every characteristic change so the gear count reflects what the device confirmed.
  void _showRangeTrimSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            Future<void> nudge(String vName, int gears) async {
              await _trimLimit(vName, gears);
              setSheetState(() {});
            }

            final shiftStep = _readInt(shiftStepVname);
            final hMin = _readInt(BLE_hMinVname);
            final hMax = _readInt(BLE_hMaxVname);
            final calibrated = shiftStep > 0 && hMax > hMin;
            final gearCount = calibrated ? ((hMax - hMin) / shiftStep).round() : 0;
            final busy = CalibrationState.isBusy(_calibrationStateNotifier.value);

            return Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(sheetContext).viewInsets.bottom + 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Fine-tune gear range", style: Theme.of(sheetContext).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    busy
                        ? "Not available while the device is calibrating."
                        : calibrated
                            ? "Currently $gearCount gears. Trim the ends if the lowest gear is too hard or the highest gear grinds."
                            : "These controls are disabled because the device has not been calibrated yet, so it does not know its own gear range. "
                                "Pedal steadily for a few seconds to start calibration, then come back here.",
                    style: Theme.of(sheetContext).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 20),
                  _buildTrimRow(
                    sheetContext,
                    label: "Lowest gear",
                    onEasier: (!busy && calibrated) ? () => nudge(BLE_hMinVname, -1) : null,
                    onHarder: (!busy && calibrated) ? () => nudge(BLE_hMinVname, 1) : null,
                  ),
                  const SizedBox(height: 12),
                  _buildTrimRow(
                    sheetContext,
                    label: "Highest gear",
                    onEasier: (!busy && calibrated) ? () => nudge(BLE_hMaxVname, -1) : null,
                    onHarder: (!busy && calibrated) ? () => nudge(BLE_hMaxVname, 1) : null,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    "Changes are saved on the device and survive a reboot. Recalibrating replaces them.",
                    style: Theme.of(sheetContext).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      child: const Text("Done"),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildTrimRow(BuildContext sheetContext, {required String label, VoidCallback? onEasier, VoidCallback? onHarder}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(child: Text(label, style: Theme.of(sheetContext).textTheme.titleMedium)),
        OutlinedButton.icon(
          onPressed: onEasier,
          icon: const Icon(Icons.remove),
          label: const Text("Easier"),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: onHarder,
          icon: const Icon(Icons.add),
          label: const Text("Harder"),
        ),
      ],
    );
  }

  /// Advisory banner when the firmware reports that the position counter probably no longer
  /// matches the knob. The device keeps working, so this informs rather than blocks.
  Widget _buildSlipBanner() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Theme.of(context).colorScheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "Gear changes stopped affecting power. The coupler may have slipped — recalibration recommended.",
              style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
        key: _scaffoldMessengerKey,
        child: Scaffold(
          appBar: SS2KAppBar(
            device: widget.device,
            title: "Virtual Shifter",
          ),
          body: Stack(
            children: [
              // Background Chart
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32.0),
                  child: Opacity(
                    opacity: _chartOpacity,
                    child: IgnorePointer(
                      child: PowerTableChart(
                        key: _chartKey,
                        device: widget.device,
                        bleData: bleData,
                        pollTargetPosition: true,
                      ),
                    ),
                  ),
                ),
              ),
              // Foreground Content
              Positioned.fill(
                child: LayoutBuilder(builder: (context, constraints) {
                  final double availH = constraints.maxHeight;
                  // Calculate dynamic sizes based on available height
                  double buttonHeight = (availH * 0.22).clamp(60.0, 160.0);
                  double gearFontSize = (buttonHeight * 0.4).clamp(24.0, 48.0);

                  return Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      SizedBox(height: 8),
                      // In the layout flow rather than a Positioned overlay: as an overlay it
                      // covered the metric cards and the up-shift button.
                      ValueListenableBuilder<int>(
                        valueListenable: _calibrationStateNotifier,
                        builder: (context, calibrationState, _) {
                          if (calibrationState != CalibrationState.slipSuspected) {
                            return const SizedBox.shrink();
                          }
                          return _buildSlipBanner();
                        },
                      ),
                      StreamBuilder<CharacteristicChangeEvent>(
                        stream: bleData.characteristicChanges,
                        builder: (context, snapshot) {
                          return SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: <Widget>[
                                if (bleData.simulatedTargetWatts != "")
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                    child: MetricBox(
                                      value: bleData.simulatedTargetWatts.toString(),
                                      label: 'Target Watts',
                                    ),
                                  ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                  child: MetricBox(
                                    value: bleData.ftmsData.watts.toString(),
                                    label: 'Watts',
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                  child: MetricBox(
                                    value: bleData.ftmsData.cadence.toString(),
                                    label: 'RPM',
                                  ),
                                ),
                                if (bleData.ftmsData.heartRate != 0)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                    child: MetricBox(
                                      value: bleData.ftmsData.heartRate.toString(),
                                      label: 'BPM',
                                    ),
                                  )
                              ],
                            ),
                          );
                        },
                      ),
                      SizedBox(height: 12),
                      // Each control listens to the calibration state separately so the layout
                      // (which relies on Spacer flex) stays a flat Column.
                      ValueListenableBuilder<int>(
                        valueListenable: _calibrationStateNotifier,
                        builder: (context, calibrationState, _) => _buildShiftButton(
                          Icons.arrow_upward,
                          CalibrationState.isBusy(calibrationState) ? null : () => shift(1),
                          height: buttonHeight,
                        ),
                      ),
                      Spacer(flex: 1),
                      ValueListenableBuilder<int>(
                        valueListenable: _calibrationStateNotifier,
                        builder: (context, calibrationState, _) {
                          // While calibrating, gear commands are queued rather than executed and
                          // the gear number jumps around meaninglessly. Show status instead.
                          if (CalibrationState.isBusy(calibrationState)) {
                            return _buildCalibrationDisplay(calibrationState, fontSize: gearFontSize);
                          }
                          return ValueListenableBuilder<String>(
                            valueListenable: _maxGearNotifier,
                            builder: (context, maxGear, _) {
                              return ValueListenableBuilder<String>(
                                valueListenable: t,
                                builder: (context, gearValue, child) {
                                  final label = maxGear != "?" ? "$gearValue/$maxGear" : gearValue;
                                  return _buildGearDisplay(label, fontSize: gearFontSize);
                                },
                              );
                            },
                          );
                        },
                      ),
                      Spacer(flex: 1),
                      ValueListenableBuilder<int>(
                        valueListenable: _calibrationStateNotifier,
                        builder: (context, calibrationState, _) => _buildShiftButton(
                          Icons.arrow_downward,
                          CalibrationState.isBusy(calibrationState) ? null : () => shift(-1),
                          height: buttonHeight,
                        ),
                      ),
                      Spacer(flex: 1),
                    ],
                  );
                }),
              ),
              Positioned(
                right: 16,
                bottom: 24,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Material(
                      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
                      shape: const CircleBorder(),
                      elevation: 4,
                      child: ValueListenableBuilder<int>(
                        valueListenable: _calibrationStateNotifier,
                        builder: (context, calibrationState, _) => IconButton(
                          tooltip: 'Fine-tune gear range',
                          icon: const Icon(Icons.tune),
                          onPressed: CalibrationState.isBusy(calibrationState) ? null : _showRangeTrimSheet,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Material(
                      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
                      shape: const CircleBorder(),
                      elevation: 4,
                      child: IconButton(
                        tooltip: _showOpacityControl ? 'Hide power table opacity' : 'Show power table opacity',
                        icon: Icon(_showOpacityControl ? Icons.opacity : Icons.opacity_outlined),
                        onPressed: () => setState(() => _showOpacityControl = !_showOpacityControl),
                      ),
                    ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: child,
                        ),
                        child: _showOpacityControl
                            ? Padding(
                                key: const ValueKey('opacityControl'),
                                padding: const EdgeInsets.only(top: 8),
                                child: _buildOpacityControl(context),
                              )
                            : const SizedBox.shrink(key: ValueKey('opacityControlEmpty')),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ));
  }

  Widget _buildOpacityControl(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 4))],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Power Table Opacity'),
              const Spacer(),
              Text('${(_chartOpacity * 100).round()}%'),
            ],
          ),
          Slider(
            value: _chartOpacity,
            min: 0.05,
            max: 0.5,
            divisions: 9,
            label: '${(_chartOpacity * 100).round()}%',
            onChanged: (value) {
              setState(() {
                _chartOpacity = value;
              });
            },
          ),
        ],
      ),
    );
  }
}
