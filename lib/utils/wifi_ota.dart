import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:flutter/services.dart' show rootBundle, MethodChannel;
import 'package:multicast_dns/multicast_dns.dart';

class WifiOTA {
  static const MethodChannel _networkChannel =
      MethodChannel('com.example.ss2kconfigapp/network');

  /// Attempts to update firmware via WiFi
  /// Returns true if successful, false if failed
  ///
  /// [manualIp] is an optional user-supplied IP address (or hostname) for the
  /// device. When provided it is tried first, so updates work even when mDNS
  /// resolution is unavailable on the phone.
  static Future<bool> updateFirmware({
    required String deviceName,
    required String firmwarePath,
    required Function(double) onProgress,
    String? manualIp,
  }) async {
    // Clean up device name for mDNS
    final cleanDeviceName = deviceName.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
    print('WiFi OTA: Starting update for device: $cleanDeviceName');
    print('WiFi OTA: Using firmware path: $firmwarePath');

    final mdnsHost = '$cleanDeviceName.local';
    String? mdnsIp;
    // In-app mDNS needs the multicast entitlement on iOS, which this app does not
    // have — MDnsClient there either throws or silently gets no replies. iOS can
    // resolve ".local" hostnames natively (once local-network permission is
    // granted), so the '$mdnsHost' candidate below covers discovery on iOS.
    if (!Platform.isIOS && cleanDeviceName.isNotEmpty) {
      // On Android, mDNS replies can be silently dropped by WiFi power-save mode
      // unless a multicast lock is held for the duration of the lookup.
      if (Platform.isAndroid) {
        await _acquireMulticastLock();
      }
      try {
        mdnsIp = await _resolveMdnsAddress(mdnsHost);
        if (mdnsIp != null) {
          print('WiFi OTA: mDNS resolved $mdnsHost to $mdnsIp');
        } else {
          print('WiFi OTA: mDNS lookup for $mdnsHost returned no address');
        }
      } finally {
        if (Platform.isAndroid) {
          await _releaseMulticastLock();
        }
      }
    }

    final trimmedManualIp = manualIp?.trim() ?? '';
    final candidates = <String>[
      if (trimmedManualIp.isNotEmpty) 'http://$trimmedManualIp',
      if (mdnsIp != null) 'http://$mdnsIp',
      if (cleanDeviceName.isNotEmpty) 'http://$mdnsHost',
      if (cleanDeviceName.isNotEmpty) 'http://$cleanDeviceName',
    ];

    String? baseUrl;
    for (final candidate in candidates) {
      print('WiFi OTA: Attempting to connect to: $candidate');
      if (await _checkDeviceAvailability(candidate)) {
        baseUrl = candidate;
        break;
      }
    }

    if (baseUrl == null) {
      print('WiFi OTA: No reachable host found for $cleanDeviceName');
      return false;
    }
    onProgress(.1);
    // Get firmware bytes - handle both asset and file paths
    List<int> firmwareBytes;
    try {
      if (firmwarePath.startsWith('assets/')) {
        print('WiFi OTA: Loading firmware from assets');
        final byteData = await rootBundle.load(firmwarePath);
        firmwareBytes = byteData.buffer.asUint8List();
      } else {
        print('WiFi OTA: Loading firmware from file system');
        final file = File(firmwarePath);
        firmwareBytes = await file.readAsBytes();
      }
      print('WiFi OTA: Firmware loaded, size: ${firmwareBytes.length} bytes');
    } catch (e) {
      print('WiFi OTA: Failed to load firmware: $e');
      return false;
    }

    try {
      // Create multipart request
      final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/update'));

      // Use a simple stream for all cases
      final multipartFile = http.MultipartFile.fromBytes(
        'update',
        firmwareBytes,
        filename: 'firmware.bin',
        contentType: MediaType('application', 'octet-stream'),
      );
      request.files.add(multipartFile);

      // Send request and animate progress while waiting for the response. The
      // response arrives only after the device has received and flashed the
      // image, so stop animating (at 95%) until it does instead of forcing a
      // fixed ~36 s countdown regardless of how fast the transfer finished.
      print('WiFi OTA: Sending firmware...');
      var prog = 0.1;
      bool responseReceived = false;
      final sendFuture = request.send().whenComplete(() {
        responseReceived = true;
      });

      while (!responseReceived && prog < 0.95) {
        onProgress(prog);
        prog = prog + .01;
        await Future.delayed(Duration(milliseconds: 400));
      }

      final response = await sendFuture;
      onProgress(1.0);
      if (response.statusCode != 200) {
        print('WiFi OTA: Upload failed, HTTP status: ${response.statusCode}');
        return false;
      }
      print('WiFi OTA: Upload successful, device will reboot');
      return true;
    } catch (e) {
      print('WiFi OTA: Upload failed: $e');
      return false;
    }
  }

  static Future<bool> _checkDeviceAvailability(String baseUrl) async {
    try {
      // 6 s is plenty for a LAN round trip; the old 15 s timeout meant probing
      // all candidates could stall the update for ~45 s before falling back to BLE.
      final response = await http
          .get(Uri.parse('$baseUrl/OTAIndex'))
          .timeout(const Duration(seconds: 6));
      if (response.statusCode == 200) {
        print('WiFi OTA: Device is available via $baseUrl');
        return true;
      }
      print('WiFi OTA: $baseUrl returned status ${response.statusCode}');
      return false;
    } catch (e) {
      print('WiFi OTA: Failed to reach $baseUrl: $e');
      return false;
    }
  }

  static Future<void> _acquireMulticastLock() async {
    try {
      await _networkChannel.invokeMethod('acquireMulticastLock');
    } catch (e) {
      print('WiFi OTA: Failed to acquire multicast lock: $e');
    }
  }

  static Future<void> _releaseMulticastLock() async {
    try {
      await _networkChannel.invokeMethod('releaseMulticastLock');
    } catch (e) {
      print('WiFi OTA: Failed to release multicast lock: $e');
    }
  }

  static Future<String?> _resolveMdnsAddress(String hostname) async {
    final client = MDnsClient();
    try {
      await client.start();
      final record = await client
          .lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(hostname))
          .timeout(const Duration(seconds: 3))
          .first;
      return record.address.address;
    } catch (e) {
      print('WiFi OTA: mDNS lookup failed for $hostname: $e');
      return null;
    } finally {
      try {
        client.stop();
      } catch (_) {}
    }
  }
}
