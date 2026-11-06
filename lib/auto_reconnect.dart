import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'ble_service.dart';
import 'storage_service.dart';
import 'worker_status.dart';

/// Automatic reconnect for the Things-X collector.
///
/// How it works: a foreground service checks the Cloudflare Worker status
/// every 2 minutes. When the inverter data has not arrived for 5 minutes,
/// the exact condition the Worker uses for its
/// "⚠️ ইনভার্টারের ডেটা আসছে না" warning, the service finds the collector
/// over Bluetooth and sends the saved Wi-Fi credentials by itself, again
/// and again until the data comes back. Once the user turns it on and
/// grants the one-time permissions, no further tap or permission is needed.
///
/// When the phone is not near the inverter, the service cannot see the
/// collector over Bluetooth. It then says so in its notification and in
/// the app: "মোবাইল ইনভার্টারের কাছে নাও". As soon as the phone comes
/// within Bluetooth range, the next check finds the collector and
/// reconnects it by itself.
class AutoReconnect {
  static const int serviceId = 256;
  static const String channelId = 'inverter_auto_reconnect';

  /// Call once at app startup, after initCommunicationPort().
  static void init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: channelId,
        channelName: 'ইনভার্টার অটো রিকানেক্ট',
        channelDescription:
            'ইনভার্টারের ডেটা বন্ধ হলে নিজে থেকে আবার যুক্ত করে।',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(120000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// One-time permissions for the service. Returns true when the
  /// notification permission is granted. Battery-optimization exemption
  /// is requested too; without it Android (and MIUI in particular) may
  /// stop the service in the background.
  static Future<bool> requestPermissions() async {
    final notificationPermission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    return await FlutterForegroundTask.checkNotificationPermission() ==
        NotificationPermission.granted;
  }

  static Future<bool> get isRunning =>
      FlutterForegroundTask.isRunningService;

  static Future<ServiceRequestResult> start() async {
    if (await FlutterForegroundTask.isRunningService) {
      return FlutterForegroundTask.restartService();
    }
    return FlutterForegroundTask.startService(
      serviceId: serviceId,
      notificationTitle: 'ইনভার্টার এক ট্যাপ',
      notificationText: 'অটো রিকানেক্ট চালু আছে',
      notificationInitialRoute: '/',
      callback: autoReconnectCallback,
    );
  }

  static Future<ServiceRequestResult> stop() =>
      FlutterForegroundTask.stopService();
}

/// Top-level callback that starts the task handler in the background
/// isolate. Must stay a top-level function.
@pragma('vm:entry-point')
void autoReconnectCallback() {
  FlutterForegroundTask.setTaskHandler(AutoReconnectTaskHandler());
}

class AutoReconnectTaskHandler extends TaskHandler {
  final _ble = CollectorBleService();
  final _storage = CredentialStorage();
  bool _busy = false;
  String _lastAttempt = 'none';
  int? _lastAttemptAt;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _sendStatus(
      stale: false,
      detail: 'অটো রিকানেক্ট চালু হয়েছে।',
    );
  }

  /// Called every 2 minutes. Runs the check without blocking the next
  /// tick; overlapping ticks are skipped.
  @override
  void onRepeatEvent(DateTime timestamp) {
    if (_busy) return;
    _busy = true;
    _tick().whenComplete(() => _busy = false);
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  Future<void> _tick() async {
    try {
      final status = await fetchWorkerStatus();
      if (status == null) {
        // Cannot reach the Worker; treat as unknown, try again next tick.
        _sendStatus(stale: false, detail: 'Worker এর সাথে যোগাযোগ হয়নি।');
        return;
      }
      if (!status.isStale) {
        await _setNotificationText('অটো রিকানেক্ট চালু আছে');
        _sendStatus(
          stale: false,
          lastState: status.lastState,
          lastVoltage: status.lastVoltage,
          lastDataTs: status.lastDataTs,
          detail: 'ডেটা আসছে।',
        );
        return;
      }
      // Data is stale: the Worker warning condition. Reconnect by itself.
      await _setNotificationText('আবার যুক্ত করার চেষ্টা চলছে');
      final ssid = await _storage.readSsid();
      final password = await _storage.readPassword();
      if (ssid == null ||
          ssid.isEmpty ||
          password == null ||
          password.isEmpty) {
        _lastAttempt = 'no_credentials';
        _lastAttemptAt = DateTime.now().millisecondsSinceEpoch;
        await _setNotificationText('ওয়াইফাই তথ্য সেভ করা নেই');
        _sendStatus(
          stale: true,
          lastState: status.lastState,
          lastVoltage: status.lastVoltage,
          lastDataTs: status.lastDataTs,
          detail: 'ওয়াইফাই তথ্য সেভ করা নেই। অ্যাপে গিয়ে একবার সেভ করো।',
        );
        return;
      }
      final found = await _ble.scanForCollector();
      if (!found) {
        _lastAttempt = 'not_near';
        _lastAttemptAt = DateTime.now().millisecondsSinceEpoch;
        await _setNotificationText('মোবাইল ইনভার্টারের কাছে নাও');
        _sendStatus(
          stale: true,
          lastState: status.lastState,
          lastVoltage: status.lastVoltage,
          lastDataTs: status.lastDataTs,
          detail: 'মোবাইল ইনভার্টারের কাছে নাও।',
        );
        return;
      }
      try {
        await _ble.provision(ssid, password);
      } catch (e) {
        _lastAttempt = 'failed';
        _lastAttemptAt = DateTime.now().millisecondsSinceEpoch;
        await _setNotificationText('আবার যুক্ত করা যায়নি, আবার চেষ্টা চলবে');
        _sendStatus(
          stale: true,
          lastState: status.lastState,
          lastVoltage: status.lastVoltage,
          lastDataTs: status.lastDataTs,
          detail: 'যুক্ত করা যায়নি: $e',
        );
        return;
      }
      // Provision sent. Give the collector a moment, then confirm data.
      await Future<void>.delayed(const Duration(seconds: 30));
      final after = await fetchWorkerStatus();
      if (after != null && !after.isStale) {
        _lastAttempt = 'success';
        _lastAttemptAt = DateTime.now().millisecondsSinceEpoch;
        await _setNotificationText('আবার যুক্ত হয়েছে');
        _sendStatus(
          stale: false,
          lastState: after.lastState,
          lastVoltage: after.lastVoltage,
          lastDataTs: after.lastDataTs,
          detail: 'আবার যুক্ত হয়েছে, ডেটা আসছে।',
        );
      } else {
        _lastAttempt = 'failed';
        _lastAttemptAt = DateTime.now().millisecondsSinceEpoch;
        await _setNotificationText('আবার যুক্ত করা যায়নি, আবার চেষ্টা চলবে');
        _sendStatus(
          stale: true,
          lastState: status.lastState,
          lastVoltage: status.lastVoltage,
          lastDataTs: status.lastDataTs,
          detail: 'পাঠানো হয়েছে, কিন্তু ডেটা এখনো আসেনি। আবার চেষ্টা চলবে।',
        );
      }
    } catch (e) {
      _sendStatus(stale: false, detail: 'চেক করতে সমস্যা: $e');
    }
  }

  Future<void> _setNotificationText(String text) async {
    try {
      await FlutterForegroundTask.updateService(notificationText: text);
    } catch (_) {
      // Notification update is best effort only.
    }
  }

  void _sendStatus({
    required bool stale,
    String? lastState,
    double? lastVoltage,
    int? lastDataTs,
    required String detail,
  }) {
    FlutterForegroundTask.sendDataToMain(<String, dynamic>{
      'type': 'auto_status',
      'checkedAt': DateTime.now().millisecondsSinceEpoch,
      'stale': stale,
      'lastState': lastState,
      'lastVoltage': lastVoltage,
      'lastDataTs': lastDataTs,
      'lastAttempt': _lastAttempt,
      'lastAttemptAt': _lastAttemptAt,
      'detail': detail,
    });
  }
}
