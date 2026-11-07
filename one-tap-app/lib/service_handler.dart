import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'ble_engine.dart';
import 'config.dart';
import 'storage_service.dart';
import 'worker_status.dart';

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(InverterTaskHandler());
}

String _two(int n) => n.toString().padLeft(2, '0');
String _hm() {
  final d = DateTime.now();
  return '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
}

/// ব্লুটুথের একমাত্র মালিক। UI কখনো ব্লুটুথ ছোঁয় না, শুধু এখান থেকে অবস্থা দেখে
/// আর কমান্ড পাঠায়। তাই দুটো চেষ্টা কখনো একসঙ্গে কালেক্টরের সাথে লড়বে না।
class InverterTaskHandler extends TaskHandler {
  final RangeScanner _scanner = RangeScanner();

  bool _auto = true;
  bool _busy = false;
  bool _tickRunning = false;

  String _progress = '';
  String _autoNote = '';
  String _lastAttempt = 'এখনো কোনো চেষ্টা হয়নি।';
  String _lastDetail = '';
  bool? _lastOk;
  List<String> _seen = [];

  WorkerSnapshot? _worker;
  int? _prevErr;
  DateTime? _lastWorkerAt;
  DateTime? _lastProvisionAt;
  String _notifText = '';

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _auto = await Storage.loadAuto();
    await _scanner.start();
    _publish();
    unawaited(_workerTick());
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    unawaited(_beat());
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    await _scanner.stop();
  }

  @override
  void onReceiveData(Object data) {
    if (data is! Map) return;
    final cmd = data['cmd'];
    if (cmd == 'provision') {
      unawaited(_runProvision(auto: false));
    } else if (cmd == 'refresh') {
      unawaited(_refresh());
    } else if (cmd == 'setAuto') {
      _auto = data['v'] == true;
      unawaited(Storage.saveAuto(_auto));
      _autoNote = _auto ? 'অটো রিকানেক্ট চালু হয়েছে।' : 'অটো রিকানেক্ট বন্ধ।';
      _publish();
      if (_auto) unawaited(_workerTick());
    } else {
      _publish(); // ping
    }
  }

  Future<void> _beat() async {
    if (!_busy) {
      await _scanner.ensureRunning();
    }
    final last = _lastWorkerAt;
    if (!_tickRunning &&
        (last == null || DateTime.now().difference(last) >= Cfg.tickEvery)) {
      unawaited(_workerTick());
    }
    _publish();
    _updateNotification();
  }

  Future<void> _refresh() async {
    if (!_busy) await _scanner.restart();
    final snap = await WorkerStatus.fetch(prevErrorCount: _prevErr);
    _prevErr = snap.errorCount;
    _worker = snap;
    _lastWorkerAt = DateTime.now();
    _publish();
  }

  Future<void> _workerTick() async {
    if (_tickRunning) return;
    _tickRunning = true;
    try {
      final snap = await WorkerStatus.fetch(prevErrorCount: _prevErr);
      _prevErr = snap.errorCount;
      _worker = snap;
      _lastWorkerAt = DateTime.now();
      _publish();
      if (!_auto || _busy) return;
      await _autoDecide(snap);
    } catch (_) {
      // পরের টিকে আবার
    } finally {
      _tickRunning = false;
      _publish();
    }
  }

  Future<void> _autoDecide(WorkerSnapshot w) async {
    switch (w.health) {
      case DataHealth.fresh:
        _lastProvisionAt = null;
        _autoNote = _scanner.inRange
            ? 'ডেটা ঠিক আছে। ফোন ইনভার্টারের কাছে আছে।'
            : 'ডেটা ঠিক আছে।';
        return;
      case DataHealth.stale:
        break;
      case DataHealth.workerUnreachable:
        _autoNote = 'Worker এর সাথে যোগাযোগ হয়নি, তাই কিছু করছি না।';
        return;
      case DataHealth.workerCloudError:
        _autoNote =
            'Worker Things-X ক্লাউডে পৌঁছাতে পারছে না। কালেক্টরকে অফলাইন ধরছি না, কিছু করছি না।';
        return;
      case DataHealth.unknown:
        _autoNote = 'ডেটার সময় জানা যায়নি, কিছু করছি না।';
        return;
    }

    if (!_scanner.inRange) {
      _autoNote = 'ডেটা পুরনো, কিন্তু ফোন ইনভার্টারের কাছে নেই।';
      return;
    }
    final lp = _lastProvisionAt;
    if (lp != null && DateTime.now().difference(lp) < Cfg.provisionCooldown) {
      _autoNote = 'সর্বশেষ চেষ্টার পর ৩ মিনিট অপেক্ষা চলছে।';
      return;
    }

    _autoNote = 'ডেটা পুরনো ও ফোন কাছে আছে। Wi-Fi পাঠাচ্ছি...';
    final r = await _runProvision(auto: true);
    if (r != null && r.ok) {
      _autoNote = 'পাঠানো হয়েছে। ৬০ সেকেন্ড পর ডেটা এসেছে কিনা দেখব।';
      _publish();
      await Future.delayed(Cfg.confirmWait);
      final w2 = await WorkerStatus.fetch(prevErrorCount: _prevErr);
      _prevErr = w2.errorCount;
      _worker = w2;
      _lastWorkerAt = DateTime.now();
      if (w2.health == DataHealth.fresh) {
        _lastAttempt = '${_hm()} অটো: ডেটা ফিরে এসেছে ✔';
        _lastOk = true;
        _autoNote = 'ডেটা ফিরে এসেছে।';
        _lastProvisionAt = null;
      } else {
        _lastAttempt =
            '${_hm()} অটো: কালেক্টর Wi-Fi মেনে নিয়েছিল, কিন্তু ৬০ সেকেন্ডে ডেটা ফেরেনি।';
        _lastOk = false;
        _autoNote = 'ডেটা এখনো ফেরেনি। ৩ মিনিট পর আবার চেষ্টা হবে।';
      }
    }
  }

  Future<ProvisionResult?> _runProvision({required bool auto}) async {
    if (_busy) return null;
    _busy = true;
    _progress = 'শুরু হচ্ছে...';
    _publish();

    ProvisionResult res;
    try {
      final c = await Storage.loadCreds();
      if (c.ssid.isEmpty || c.pass.isEmpty) {
        res = const ProvisionResult(false, 'no_creds',
            'Wi-Fi এর নাম বা পাসওয়ার্ড সেভ করা নেই। নিচে লিখে সেভ করুন।');
      } else {
        res = await Provisioner.run(
          ssid: c.ssid,
          pass: c.pass,
          scanner: _scanner,
          onProgress: (s) {
            _progress = s;
            _publish();
          },
        );
      }
    } catch (e) {
      res = ProvisionResult(false, 'error', 'অপ্রত্যাশিত সমস্যা হয়েছে।',
          const <String>[], e.toString());
    }

    _lastAttempt = '${_hm()} ${auto ? 'অটো' : 'ম্যানুয়াল'}: ${res.message}';
    _lastDetail = res.detail;
    _lastOk = res.ok;
    if (res.seen.isNotEmpty) _seen = res.seen;
    if (res.stage != 'not_in_range' &&
        res.stage != 'bluetooth_off' &&
        res.stage != 'no_creds') {
      _lastProvisionAt = DateTime.now();
    }
    _busy = false;
    _progress = '';
    _publish();
    return res;
  }

  Map<String, dynamic> _state() {
    final ls = _scanner.lastSeen;
    return {
      'hb': DateTime.now().millisecondsSinceEpoch,
      'auto': _auto,
      'busy': _busy,
      'progress': _progress,
      'range': _scanner.rangeState(),
      'rssi': _scanner.lastRssi,
      'lastSeenSec':
          ls == null ? null : DateTime.now().difference(ls).inSeconds,
      'scanErr': _scanner.error,
      'btOff': FlutterBluePlus.adapterStateNow == BluetoothAdapterState.off,
      'worker': _worker?.toMap(),
      'workerAt': _lastWorkerAt?.millisecondsSinceEpoch,
      'lastAttempt': _lastAttempt,
      'lastDetail': _lastDetail,
      'lastOk': _lastOk,
      'seen': _seen,
      'autoNote': _autoNote,
    };
  }

  void _publish() {
    FlutterForegroundTask.sendDataToMain(_state());
  }

  void _updateNotification() {
    final r = _scanner.rangeState();
    final rt = r == 'in'
        ? 'কালেক্টর কাছে আছে'
        : (r == 'out' ? 'কালেক্টর কাছে নেই' : 'কালেক্টর খুঁজছি');
    final text = '$rt • অটো ${_auto ? 'চালু' : 'বন্ধ'}';
    if (text == _notifText) return;
    _notifText = text;
    FlutterForegroundTask.updateService(
      notificationTitle: 'ইনভার্টার এক ট্যাপ',
      notificationText: text,
    );
  }
}
