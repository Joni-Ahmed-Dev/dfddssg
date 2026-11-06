import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'config.dart';

/// A tiny queue for characteristic indications. Values that arrive while
/// nobody is waiting are buffered; [next] returns the oldest buffered
/// value, or waits for the next one up to [timeout].
class _ValueQueue {
  final _values = <List<int>>[];
  final _waiters = <Completer<List<int>>>[];

  void add(List<int> value) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(value);
    } else {
      _values.add(value);
    }
  }

  Future<List<int>> next({required Duration timeout}) {
    if (_values.isNotEmpty) {
      return Future<List<int>>.value(_values.removeAt(0));
    }
    final completer = Completer<List<int>>();
    _waiters.add(completer);
    return completer.future.timeout(timeout);
  }
}

BluetoothCharacteristic? _findChar(
  List<BluetoothService> services,
  String serviceUuid,
  String charUuid,
) {
  for (final service in services) {
    if (service.uuid.str.toLowerCase() != serviceUuid.toLowerCase()) {
      continue;
    }
    for (final c in service.characteristics) {
      if (c.uuid.str.toLowerCase() == charUuid.toLowerCase()) {
        return c;
      }
    }
  }
  return null;
}

String _asText(List<int> value) {
  try {
    return utf8.decode(value);
  } catch (_) {
    return '';
  }
}

/// Handles one job only: find the collector, connect, write the saved
/// Wi-Fi credentials, disconnect. No pairing, no SSID search, no typing
/// happens at provision time. All of that was done once, at setup.
///
/// Protocol, from the 2026-11-06 HCI snoop log (two complete Things-X
/// setups): plain ASCII commands over BLE, no pairing, no encryption.
///  - 0xFF97 (scan channel): "scanwifi" -> indication "ok";
///    "getwifi" (repeat) -> JSON scan results, then "endwifi".
///  - 0xFF99 (command channel): "WIFI_SET <SSID> <password>".
///  - 0xFF22 (response channel): JSON indication, e.g.
///    {"code":0,"msg":"wifi *** OK! OK! ***","cmd":"wifi_set"}.
/// Never logs the payload: it contains the password.
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

  /// Connects, runs the Wi-Fi scan, writes the credentials, waits for
  /// the collector's own confirmation, then disconnects.
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
      final cmd = _findChar(
        services,
        CollectorConfig.serviceUuid,
        CollectorConfig.characteristicUuid,
      );
      final scan = _findChar(
        services,
        CollectorConfig.serviceUuid,
        CollectorConfig.scanCharacteristicUuid,
      );
      final resp = _findChar(
        services,
        CollectorConfig.responseServiceUuid,
        CollectorConfig.responseCharacteristicUuid,
      );
      if (cmd == null || scan == null || resp == null) {
        throw StateError('কালেক্টরে লেখার জায়গাটা পাওয়া যায়নি। UUID গুলো আবার মিলিয়ে দেখো।');
      }

      final scanQueue = _ValueQueue();
      final respQueue = _ValueQueue();
      final scanSub = scan.onValueReceived.listen(scanQueue.add);
      final respSub = resp.onValueReceived.listen(respQueue.add);
      try {
        // Enable indications on both channels (CCCD 0x0200).
        await resp.setNotifyValue(true);
        await scan.setNotifyValue(true);

        // 1. Start a Wi-Fi scan, wait for "ok".
        await scan.write(
          Uint8List.fromList(utf8.encode('scanwifi')),
          withoutResponse: false,
        );
        final ok = await scanQueue.next(timeout: const Duration(seconds: 10));
        if (_asText(ok) != 'ok') {
          throw StateError('কালেক্টর স্ক্যান শুরু করলো না। আবার চেষ্টা করো।');
        }

        // 2. Poll getwifi until the scan ends ("endwifi"), at most 30s.
        // Results arrive as JSON chunks; they are only for the list,
        // the real test is the WIFI_SET reply below, so a timeout here
        // does not fail the job.
        final scanDeadline = DateTime.now().add(const Duration(seconds: 30));
        while (DateTime.now().isBefore(scanDeadline)) {
          await scan.write(
            Uint8List.fromList(utf8.encode('getwifi')),
            withoutResponse: false,
          );
          try {
            final value = await scanQueue.next(timeout: const Duration(seconds: 3));
            if (_asText(value) == 'endwifi') break;
          } on TimeoutException {
            // No reply yet; ask again.
            continue;
          }
        }

        // 3. Send the credentials.
        final Uint8List payload = CollectorConfig.buildPayload(ssid, password);
        await cmd.write(payload, withoutResponse: false);

        // 4. Wait for the collector's own confirmation on 0xFF22.
        final confirmDeadline = DateTime.now().add(const Duration(seconds: 20));
        while (DateTime.now().isBefore(confirmDeadline)) {
          final remaining = confirmDeadline.difference(DateTime.now());
          final value = await respQueue.next(timeout: remaining);
          final text = _asText(value);
          if (!text.contains('"cmd":"wifi_set"')) continue;
          final Map<String, dynamic> reply =
              jsonDecode(text) as Map<String, dynamic>;
          if (reply['code'] == 0) {
            return; // Success. Disconnect in the finally below.
          }
          throw StateError('কালেক্টর নিলো না: ${reply['msg'] ?? 'অজানা কারণ'}');
        }
        throw StateError('কালেক্টর থেকে নিশ্চিতকরণ আসেনি। ওয়াইফাই নাম আর পাসওয়ার্ড মিলিয়ে আবার চেষ্টা করো।');
      } finally {
        await scanSub.cancel();
        await respSub.cancel();
      }
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
