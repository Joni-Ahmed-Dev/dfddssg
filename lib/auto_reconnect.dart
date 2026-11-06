import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'ble_service.dart';
import 'storage_service.dart';
import 'worker_status.dart';

/// Automatic reconnect for the Things-X collector.
///
/// How it works: a foreground service checks the Cloudflare Worker status
/// every minute. When the inverter data has not arrived for 2 minutes
/// (data normally arrives about once a minute), the service finds the
/// collector over Bluetooth and sends the saved Wi-Fi credentials by
/// itself, again and again until the data comes back. Once the user
/// turns it on and grants the one-time permissions, no further tap or
/// permission is needed.
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
        eventAction: ForegroundTaskEventAction.repeat(60000),
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
  // Whether the collector is in Bluetooth range right now, as seen by
  // the last scan. Null means no scan has reported yet.
  bool? _lastInRange;
  // When the credentials were last sent. The collector needs a minute
  // or two to join Wi-Fi and upload data after WIFI_SET, so a new
  // provision inside this window would only interrupt it.
  DateTime? _lastProvisionAt;
  static const Duration _provisionCooldown = Duration(minutes: 3);

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _sendStatus(
      stale: false,
      detail: 'অটো রিকানেক্ট চালু হয়েছে।',
    );
  }

  /// Called every minute. Runs the check without blocking the next
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
      // Is the collector in Bluetooth range right now? One scan serves
      // both the range display and the provision below, so the device
      // found here is reused instead of scanning again.
      final inRange = await _ble.scanForCollector(
        timeout: const Duration(seconds: 10),
      );
      _lastInRange = inRange;
      if (!status.isStale) {
        // Data is flowing again; clear any old attempt shown in the app.
        _lastAttempt = 'none';
        _lastAttemptAt = null;
        await _setNotificationText(
          inRange
              ? 'অটো রিকানেক্ট চালু আছে, ইনভার্টার কাছে আছে'
              : 'অটো রিকানেক্ট চালু আছে',
        );
        _sendStatus(
          stale: false,
          lastState: status.lastState,
          lastVoltage: status.lastVoltage,
          lastDataTs: status.lastDataTs,
          inRange: inRange,
          detail: inRange
              ? 'ডেটা আসছে, ইনভার্টার ব্লুটুথে পাওয়া গেছে।'
              : 'ডেটা আসছে।',
        );
        return;
      }
      // Data is stale. When the collector is out of range there is
      // nothing to connect to; the app shows it is still scanning.
      if (!inRange) {
        _lastAttempt = 'not_near';
        _lastAttemptAt = DateTime.now().millisecondsSinceEpoch;
        await _setNotificationText('মোবাইল ইনভার্টারের কাছে নাও');
        _sendStatus(
          stale: true,
          lastState: status.lastState,
          lastVoltage: status.lastVoltage,
          lastDataTs: status.lastDataTs,
          inRange: inRange,
          detail: 'মোবাইল ইনভার্টারের কাছে নাও।',
        );
        return;
      }
      // Data is stale and the collector is in range: connect by itself
      // and send the saved Wi-Fi credentials.
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
          inRange: inRange,
          detail: 'ওয়াইফাই তথ্য সেভ করা নেই। অ্যাপে গিয়ে একবার সেভ করো।',
        );
        return;
      }
      // Do not send the credentials again while the collector is still
      // joining Wi-Fi from the last provision; it would interrupt it.
      if (_lastProvisionAt != null &&
          DateTime.now().difference(_lastProvisionAt!) < _provisionCooldown) {
        await _setNotificationText('আবার যুক্ত করার চেষ্টা চলছে');
        _sendStatus(
          stale: true,
          lastState: status.lastState,
          lastVoltage: status.lastVoltage,
          lastDataTs: status.lastDataTs,
          inRange: inRange,
          detail: 'পাঠানো হয়েছে, কালেক্টর যুক্ত হওয়ার অপেক্ষায় আছি।',
        );
        return;
      }
      await _setNotificationText('আবার যুক্ত করার চেষ্টা চলছে');
      try {
        await _ble.provision(ssid, password);
        _lastProvisionAt = DateTime.now();
      } catch (e) {
        _lastAttempt = 'failed';
        _lastAttemptAt = DateTime.now().millisecondsSinceEpoch;
        await _setNotificationText('আবার যুক্ত করা যায়নি, আবার চেষ্টা চলবে');
        _sendStatus(
          stale: true,
          lastState: status.lastState,
          lastVoltage: status.lastVoltage,
          lastDataTs: status.lastDataTs,
          inRange: inRange,
          detail: 'যুক্ত করা যায়নি: $e',
        );
        return;
      }
      // Provision sent. Give the collector a minute to join Wi-Fi and
      // upload data, then confirm data is flowing again.
      await Future<void>.delayed(const Duration(seconds: 60));
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
          inRange: inRange,
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
          inRange: inRange,
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
    bool? inRange,
    required String detail,
  }) {
    FlutterForegroundTask.sendDataToMain(<String, dynamic>{
      'type': 'auto_status',
      'checkedAt': DateTime.now().millisecondsSinceEpoch,
      'stale': stale,
      'lastState': lastState,
      'lastVoltage': lastVoltage,
      'lastDataTs': lastDataTs,
      'inRange': inRange ?? _lastInRange,
      'lastAttempt': _lastAttempt,
      'lastAttemptAt': _lastAttemptAt,
      'detail': detail,
    });
  }
}
