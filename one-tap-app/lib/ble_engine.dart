import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'config.dart';

/// ============================================================
/// RangeScanner: একটাই চলমান স্ক্যান। বারবার শুরু/বন্ধ করা হয় না
/// (Android ৩০ সেকেন্ডে ৫ বারের বেশি স্ক্যান শুরু করতে দেয় না)।
/// "কাছে আছে" = শেষ ১০ সেকেন্ডের মধ্যে কালেক্টরের বিজ্ঞাপন দেখা গেছে।
/// ============================================================
class RangeScanner {
  DateTime? lastSeen;
  int? lastRssi;
  String? error;
  bool paused = false;

  DateTime? _startedAt;
  DateTime _lastStartTry = DateTime.fromMillisecondsSinceEpoch(0);
  StreamSubscription<List<ScanResult>>? _sub;

  static Future<bool> btIsOn() async {
    try {
      final s = await FlutterBluePlus.adapterState
          .where((x) => x != BluetoothAdapterState.unknown)
          .first
          .timeout(const Duration(seconds: 3));
      return s == BluetoothAdapterState.on;
    } catch (_) {
      return false;
    }
  }

  void _attach() {
    _sub ??= FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        if (r.device.remoteId.str.toUpperCase() == Cfg.collectorMac) {
          lastSeen = DateTime.now();
          lastRssi = r.rssi;
        }
      }
    }, onError: (Object e) {
      error = 'স্ক্যানে সমস্যা হয়েছে।';
    });
  }

  Future<void> _startScan() async {
    _lastStartTry = DateTime.now();
    try {
      if (!await btIsOn()) {
        error = 'ফোনের ব্লুটুথ বন্ধ আছে।';
        return;
      }
      await FlutterBluePlus.startScan(
        withRemoteIds: [Cfg.collectorMac],
        androidScanMode: AndroidScanMode.lowLatency,
        continuousUpdates: true,
        androidUsesFineLocation: true,
      );
      error = null;
      _startedAt ??= DateTime.now();
    } catch (e) {
      error =
          'স্ক্যান শুরু হয়নি। ব্লুটুথ/লোকেশন অনুমতি আর লোকেশন চালু আছে কিনা দেখুন।';
    }
  }

  Future<void> start() async {
    paused = false;
    _attach();
    await _startScan();
  }

  /// প্রতি হার্টবিটে ডাকা হয়; স্ক্যান থেমে গেলে ২০ সেকেন্ডের বেশি পর আবার চালু করে।
  Future<void> ensureRunning() async {
    if (paused) return;
    if (FlutterBluePlus.isScanningNow) return;
    if (DateTime.now().difference(_lastStartTry) < const Duration(seconds: 20)) {
      return;
    }
    _attach();
    await _startScan();
  }

  Future<void> pause() async {
    paused = true;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  Future<void> resume() async {
    paused = false;
    _attach();
    _lastStartTry = DateTime.fromMillisecondsSinceEpoch(0);
    await _startScan();
  }

  Future<void> restart() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 300));
    await resume();
  }

  Future<void> stop() async {
    paused = true;
    await _sub?.cancel();
    _sub = null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  /// 'searching' | 'in' | 'out'
  String rangeState() {
    final now = DateTime.now();
    final ls = lastSeen;
    if (ls != null && now.difference(ls) < Cfg.rangeWindow) return 'in';
    if (ls == null &&
        (_startedAt == null || now.difference(_startedAt!) < Cfg.rangeWindow)) {
      return 'searching';
    }
    return 'out';
  }

  bool get inRange => rangeState() == 'in';
}

/// ============================================================
/// Provision ফলাফল
/// ============================================================
class ProvisionResult {
  final bool ok;
  final String stage;
  final String message;
  final List<String> seen;
  final String detail;
  const ProvisionResult(this.ok, this.stage, this.message,
      [this.seen = const <String>[], this.detail = '']);
}

class _Inbox {
  final List<String> _items = [];
  Completer<void>? _c;

  void add(String s) {
    _items.add(s);
    final c = _c;
    if (c != null && !c.isCompleted) c.complete();
  }

  Future<String?> next(Duration t) async {
    if (_items.isEmpty) {
      final c = Completer<void>();
      _c = c;
      try {
        await c.future.timeout(t);
      } on TimeoutException {
        _c = null;
        return null;
      }
      _c = null;
    }
    return _items.isEmpty ? null : _items.removeAt(0);
  }

  void clear() => _items.clear();
}

Future<String?> _waitMatch(
    _Inbox box, bool Function(String) test, Duration timeout) async {
  final end = DateTime.now().add(timeout);
  while (true) {
    final left = end.difference(DateTime.now());
    if (left <= Duration.zero) return null;
    final m = await box.next(left);
    if (m == null) return null;
    if (test(m)) return m;
  }
}

String _short(Object e) {
  final s = e.toString();
  return s.length > 140 ? s.substring(0, 140) : s;
}

/// ============================================================
/// Provisioner: scanwifi → getwifi... → (SSID দেখা গেলে) WIFI_SET → নিশ্চিতকরণ
/// ============================================================
class Provisioner {
  static Future<ProvisionResult> run({
    required String ssid,
    required String pass,
    required RangeScanner scanner,
    required void Function(String) onProgress,
  }) async {
    final lens =
        'SSID ${ssid.length} অক্ষর, পাসওয়ার্ড ${pass.length} অক্ষর (শুরু/শেষের স্পেস ও অদৃশ্য অক্ষর বাদ)';

    if (!await RangeScanner.btIsOn()) {
      return const ProvisionResult(
          false, 'bluetooth_off', 'ফোনের ব্লুটুথ বন্ধ আছে। ব্লুটুথ চালু করুন।');
    }

    await scanner.ensureRunning();
    if (!scanner.inRange) {
      onProgress('ব্লুটুথে কালেক্টর খুঁজছি...');
      final end = DateTime.now().add(const Duration(seconds: 8));
      while (!scanner.inRange && DateTime.now().isBefore(end)) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (!scanner.inRange) {
        return const ProvisionResult(
            false,
            'not_in_range',
            'কালেক্টর ব্লুটুথে দেখা যাচ্ছে না। ইনভার্টারের কাছে যান। Things-X (বা অন্য অ্যাপ) কালেক্টরকে ধরে রাখলেও এমন হয়, তাই Things-X পুরো বন্ধ করুন।');
      }
    }

    await scanner.pause();
    await Future.delayed(const Duration(milliseconds: 500));

    final device = BluetoothDevice.fromId(Cfg.collectorMac);
    final scanIn = _Inbox();
    final respIn = _Inbox();
    StreamSubscription<List<int>>? s1;
    StreamSubscription<List<int>>? s2;
    bool connected = false;
    String step = 'সংযোগ';

    try {
      onProgress('কালেক্টরের সাথে সংযোগ করছি...');
      try {
        await device.connect(
            timeout: const Duration(seconds: 20), autoConnect: false);
        connected = true;
      } catch (e) {
        return ProvisionResult(
            false,
            'busy',
            'কালেক্টরের সাথে ব্লুটুথ সংযোগ হয়নি। Things-X বা অন্য কোনো অ্যাপ কালেক্টরকে ধরে রেখেছে কি? Things-X পুরো বন্ধ করে আবার চেষ্টা করুন।',
            const <String>[],
            _short(e));
      }

      step = 'সার্ভিস খোঁজা';
      onProgress('কালেক্টরের তথ্য পড়ছি...');
      final services = await device.discoverServices();
      BluetoothCharacteristic? cmd;
      BluetoothCharacteristic? scan;
      BluetoothCharacteristic? resp;
      final found = <String>[];
      for (final s in services) {
        for (final c in s.characteristics) {
          final u = c.uuid.str128.toLowerCase();
          found.add(u.substring(4, 8));
          if (u.startsWith('0000ff99')) cmd = c;
          if (u.startsWith('0000ff97')) scan = c;
          if (u.startsWith('0000ff22')) resp = c;
        }
      }
      if (cmd == null || scan == null || resp == null) {
        return ProvisionResult(
            false,
            'error',
            'কালেক্টরের প্রয়োজনীয় ব্লুটুথ চ্যানেল পাওয়া যায়নি। (পাওয়া গেছে: ${found.join(', ')})',
            const <String>[],
            lens);
      }

      s1 = scan.onValueReceived.listen(
          (v) => scanIn.add(utf8.decode(v, allowMalformed: true).trim()));
      s2 = resp.onValueReceived.listen(
          (v) => respIn.add(utf8.decode(v, allowMalformed: true).trim()));

      step = 'ইন্ডিকেশন চালু';
      await resp.setNotifyValue(true);
      await scan.setNotifyValue(true);

      // --- scanwifi ---
      step = 'scanwifi';
      onProgress('কালেক্টর Wi-Fi স্ক্যান শুরু করছে...');
      await scan.write(utf8.encode('scanwifi'));
      final ok = await _waitMatch(
          scanIn, (m) => m.toLowerCase() == 'ok', const Duration(seconds: 10));
      if (ok == null) {
        return ProvisionResult(
            false,
            'scan_not_started',
            'কালেক্টর Wi-Fi স্ক্যান শুরু করেনি (১০ সেকেন্ডে "ok" আসেনি)। আবার চেষ্টা করুন।',
            const <String>[],
            lens);
      }

      // --- getwifi loop ---
      step = 'getwifi';
      onProgress('কালেক্টর কোন Wi-Fi দেখছে তা জানছি...');
      final seen = <String>[];
      final end = DateTime.now().add(const Duration(seconds: 30));
      bool ended = false;
      while (!ended && DateTime.now().isBefore(end)) {
        await scan.write(utf8.encode('getwifi'));
        final msg = await scanIn.next(const Duration(seconds: 2));
        if (msg == null || msg.isEmpty) continue;
        if (msg == 'endwifi') {
          ended = true;
          break;
        }
        try {
          final j = jsonDecode(msg);
          if (j is List) {
            for (final e in j) {
              if (e is Map && e['s'] is String) {
                final n = e['s'] as String;
                if (!seen.contains(n)) seen.add(n);
              }
            }
          }
        } catch (_) {}
      }

      if (!seen.contains(ssid)) {
        final list = seen.isEmpty ? 'কোনো নেটওয়ার্কই না' : seen.join(', ');
        return ProvisionResult(
            false,
            'ssid_not_seen',
            'কালেক্টর আপনার Wi-Fi "$ssid" দেখতে পায়নি, তাই পাসওয়ার্ড পাঠাইনি। কালেক্টর দেখেছে: $list.${ended ? '' : ' (স্ক্যান ৩০ সেকেন্ডে শেষ হয়নি)'}',
            seen,
            lens);
      }

      // --- WIFI_SET ---
      step = 'WIFI_SET';
      onProgress('Wi-Fi এর নাম ও পাসওয়ার্ড পাঠাচ্ছি...');
      respIn.clear();
      await cmd.write(utf8.encode('WIFI_SET $ssid $pass'));

      step = 'নিশ্চিতকরণ';
      onProgress('কালেক্টরের উত্তরের অপেক্ষা (সর্বোচ্চ ২০ সেকেন্ড)...');
      final reply = await _waitMatch(respIn, (m) {
        try {
          final j = jsonDecode(m);
          return j is Map && j['cmd'] == 'wifi_set';
        } catch (_) {
          return false;
        }
      }, const Duration(seconds: 20));

      if (reply == null) {
        return ProvisionResult(
            false,
            'no_confirmation',
            'পাসওয়ার্ড পাঠানো হয়েছে কিন্তু ২০ সেকেন্ডে কালেক্টর কিছু জানায়নি।',
            seen,
            lens);
      }
      final j = jsonDecode(reply) as Map;
      final code = j['code'];
      if (code == 0) {
        return ProvisionResult(
            true,
            'ok',
            'কালেক্টর Wi-Fi মেনে নিয়েছে। ডেটা ফিরতে এক-দুই মিনিট লাগতে পারে।',
            seen,
            lens);
      }
      return ProvisionResult(
          false,
          'collector_no',
          'কালেক্টর Wi-Fi তে যুক্ত হতে পারেনি (সে "NO" বলেছে), যদিও সে আপনার Wi-Fi দেখতে পেয়েছিল।',
          seen,
          '$lens; কালেক্টরের উত্তর: $reply');
    } catch (e) {
      return ProvisionResult(
          false,
          'error',
          'ধাপ "$step" এ সমস্যা হয়েছে। আবার চেষ্টা করুন।',
          const <String>[],
          _short(e));
    } finally {
      await s1?.cancel();
      await s2?.cancel();
      if (connected) {
        // কাজ শেষ: সঙ্গে সঙ্গে ছেড়ে দেওয়া, যাতে কালেক্টর Wi-Fi তে মন দিতে পারে
        await Future.delayed(const Duration(milliseconds: 1500));
        try {
          await device.disconnect();
        } catch (_) {}
        scanner.lastSeen = DateTime.now();
      }
      await Future.delayed(const Duration(seconds: 1));
      await scanner.resume();
    }
  }
}
