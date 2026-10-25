import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'config.dart';

/// Handles one job only: find the collector, connect, write the saved
/// Wi-Fi credentials, disconnect. No pairing, no SSID search, no typing
/// happens at provision time. All of that was done once, at setup.
class CollectorBleService {
  BluetoothDevice? _device;

  /// Scans for up to [timeout] and returns true if the collector MAC
  /// is seen advertising. The caller decides what to show the user.
  Future<bool> scanForCollector({Duration timeout = const Duration(seconds: 12)}) async {
    _device = null;
    await FlutterBluePlus.startScan(timeout: timeout);
    await for (final result in FlutterBluePlus.scanResults) {
      final remoteId = result.device.remoteId.str.toUpperCase();
      if (remoteId == CollectorConfig.collectorMac.toUpperCase()) {
        _device = result.device;
        await FlutterBluePlus.stopScan();
        return true;
      }
    }
    await FlutterBluePlus.stopScan();
    return _device != null;
  }

  /// Connects, writes the credentials, disconnects.
  /// Throws a readable message on failure. Never logs the payload.
  Future<void> provision(String ssid, String password) async {
    if (CollectorConfig.payloadMode == 'todo') {
      throw StateError(
        'প্রোটোকল এখনো জানা যায়নি। HCI স্নুপ লগ থেকে '
        'service, characteristic আর ডেটা ফরম্যাট বসাতে হবে।',
      );
    }
    final device = _device;
    if (device == null) {
      throw StateError('কালেক্টর পাওয়া যায়নি। ইনভার্টারের কাছে গিয়ে আবার চেষ্টা করো।');
    }
    try {
      await device.connect(timeout: const Duration(seconds: 15));
      final services = await device.discoverServices();
      BluetoothCharacteristic? target;
      for (final service in services) {
        if (service.uuid.str.toLowerCase() != CollectorConfig.serviceUuid.toLowerCase()) {
          continue;
        }
        for (final c in service.characteristics) {
          if (c.uuid.str.toLowerCase() == CollectorConfig.characteristicUuid.toLowerCase()) {
            target = c;
          }
        }
      }
      if (target == null) {
        throw StateError('কালেক্টরে লেখার জায়গাটা পাওয়া যায়নি। UUID গুলো আবার মিলিয়ে দেখো।');
      }
      final Uint8List payload = CollectorConfig.buildPayload(ssid, password);
      await target.write(payload, withoutResponse: false);
      // Give the collector a moment to act on the write before we drop.
      await Future<void>.delayed(const Duration(seconds: 3));
    } finally {
      try {
        await device.disconnect();
      } catch (_) {
        // Disconnect best effort only; the write result above is what matters.
      }
      _device = null;
    }
  }
}
