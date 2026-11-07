import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'service_handler.dart';
import 'storage_service.dart';

void main() {
  FlutterForegroundTask.initCommunicationPort();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ইনভার্টার এক ট্যাপ',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final _ssidC = TextEditingController();
  final _passC = TextEditingController();
  Map<String, dynamic> _st = {};
  DateTime? _lastHb;
  bool _alive = false;
  bool _permsOk = false;
  bool _obscure = true;
  String _saveInfo = '';
  Timer? _timer;
  DateTime _lastStartTry = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FlutterForegroundTask.addTaskDataCallback(_onData);
    _initService();
    _loadCreds();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _watch());
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FlutterForegroundTask.removeTaskDataCallback(_onData);
    _timer?.cancel();
    _ssidC.dispose();
    _passC.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      FlutterForegroundTask.sendDataToTask({'cmd': 'ping'});
    }
  }

  void _initService() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'inverter_one_tap',
        channelName: 'ইনভার্টার এক ট্যাপ',
        channelDescription: 'ব্যাকগ্রাউন্ডে কালেক্টর পাহারা',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(2000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  Future<void> _loadCreds() async {
    final c = await Storage.loadCreds();
    if (!mounted) return;
    setState(() {
      _ssidC.text = c.ssid;
      _passC.text = c.pass;
    });
  }

  void _onData(Object data) {
    if (data is Map && mounted) {
      _lastHb = DateTime.now();
      setState(() => _st = Map<String, dynamic>.from(data));
    }
  }

  Future<bool> _perms({required bool ask}) async {
    final list = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
      Permission.notification,
    ];
    var ok = true;
    for (final p in list) {
      var s = await p.status;
      if (!s.isGranted && ask) s = await p.request();
      if (!s.isGranted) ok = false;
    }
    return ok;
  }

  Future<void> _boot() async {
    _permsOk = await _perms(ask: false);
    if (mounted) setState(() {});
    if (_permsOk) {
      final running = await FlutterForegroundTask.isRunningService;
      if (running) {
        FlutterForegroundTask.sendDataToTask({'cmd': 'ping'});
      } else {
        await _startOrRestart();
      }
    }
  }

  Future<void> _startOrRestart() async {
    _lastStartTry = DateTime.now();
    try {
      final running = await FlutterForegroundTask.isRunningService;
      if (running) {
        await FlutterForegroundTask.restartService();
      } else {
        await FlutterForegroundTask.startService(
          notificationTitle: 'ইনভার্টার এক ট্যাপ',
          notificationText: 'চালু হচ্ছে...',
          callback: startCallback,
        );
      }
    } catch (_) {}
  }

  void _watch() {
    final alive = _lastHb != null &&
        DateTime.now().difference(_lastHb!) < const Duration(seconds: 8);
    if (alive != _alive && mounted) setState(() => _alive = alive);
    if (!alive &&
        _permsOk &&
        DateTime.now().difference(_lastStartTry) > const Duration(seconds: 25)) {
      _startOrRestart();
    }
  }

  Future<void> _askPerms() async {
    final ok = await _perms(ask: true);
    _permsOk = ok;
    if (ok) {
      await Permission.ignoreBatteryOptimizations.request();
      await _startOrRestart();
    }
    if (mounted) setState(() {});
  }

  void _oneTap() {
    FlutterForegroundTask.sendDataToTask({'cmd': 'provision'});
  }

  Future<void> _toggleAuto(bool v) async {
    if (v && !_permsOk) await _askPerms();
    FlutterForegroundTask.sendDataToTask({'cmd': 'setAuto', 'v': v});
  }

  Future<void> _save() async {
    await Storage.saveCreds(_ssidC.text, _passC.text);
    final c = await Storage.loadCreds();
    if (!mounted) return;
    setState(() {
      _ssidC.text = c.ssid;
      _passC.text = c.pass;
      _saveInfo =
          'সেভ হয়েছে: Wi-Fi নাম ${c.ssid.length} অক্ষর, পাসওয়ার্ড ${c.pass.length} অক্ষর (শুরু/শেষের স্পেস ও অদৃশ্য অক্ষর বাদ দেওয়া হয়েছে)।';
    });
  }

  // ---------- UI helpers ----------
  String _two(int n) => n.toString().padLeft(2, '0');

  Widget _dot(Color c) => Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(color: c, shape: BoxShape.circle),
      );

  Widget _card(List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      );

  Widget _rangeCard() {
    final busy = _st['busy'] == true;
    final range = (_st['range'] as String?) ?? 'searching';
    final btOff = _st['btOff'] == true;
    final scanErr = _st['scanErr'] as String?;
    Color color;
    String text;
    if (!_alive) {
      color = Colors.grey;
      text = 'সার্ভিসের সাড়া নেই...';
    } else if (busy) {
      color = Colors.blue;
      text = 'কালেক্টরের সাথে কথা চলছে (ব্লুটুথ ব্যস্ত)।';
    } else if (range == 'in') {
      color = Colors.green;
      text = 'ইনভার্টার ব্লুটুথে পাওয়া গেছে, কাছে আছে।';
    } else if (range == 'out') {
      color = Colors.amber;
      text = 'ইনভার্টার ব্লুটুথে নেই, কাছে নেই।';
    } else {
      color = Colors.grey;
      text = 'ইনভার্টার খুঁজছে...';
    }
    final rssi = _st['rssi'];
    return _card([
      Row(children: [
        _dot(color),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 16))),
      ]),
      if (_alive && !busy && range == 'in' && rssi != null)
        Text('সিগন্যাল: $rssi dBm',
            style: const TextStyle(color: Colors.black54)),
      if (_alive && !busy && range == 'out')
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'ইনভার্টারের পাশে থাকলেও এটা দেখালে Things-X পুরো বন্ধ করুন। Things-X কালেক্টরকে ধরে রাখলে সে ব্লুটুথে দেখা দেয় না।',
            style: TextStyle(color: Colors.black54),
          ),
        ),
      if (btOff)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(children: [
            const Expanded(
                child: Text('ফোনের ব্লুটুথ বন্ধ আছে।',
                    style: TextStyle(color: Colors.red))),
            TextButton(
              onPressed: () async {
                try {
                  await FlutterBluePlus.turnOn();
                } catch (_) {}
              },
              child: const Text('চালু করুন'),
            ),
          ]),
        ),
      if (scanErr != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(scanErr, style: const TextStyle(color: Colors.red)),
        ),
    ]);
  }

  Widget _oneTapButton() {
    final busy = _st['busy'] == true;
    final progress = (_st['progress'] as String?) ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(
        height: 92,
        child: FilledButton(
          onPressed: (!_alive || busy) ? null : _oneTap,
          child: Text(
            busy
                ? (progress.isEmpty ? 'চলছে...' : progress)
                : 'এক ট্যাপে কালেক্টর কানেক্ট করো',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20),
          ),
        ),
      ),
    );
  }

  Widget _workerCard() {
    final w = _st['worker'] as Map?;
    final at = _st['workerAt'] as int?;
    String when = '';
    if (at != null) {
      final d = DateTime.fromMillisecondsSinceEpoch(at);
      when = 'শেষ চেক ${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
    }
    final extra = <String>[];
    if (w != null) {
      if (w['state'] != null) extra.add('গ্রিড: ${w['state']}');
      if (w['voltage'] != null) extra.add('ভোল্টেজ: ${w['voltage']}');
    }
    return _card([
      const Text('ডেটার অবস্থা (Worker)',
          style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      Text(w == null ? 'এখনো চেক হয়নি...' : '${w['text']}'),
      if (extra.isNotEmpty)
        Text(extra.join(' • '), style: const TextStyle(color: Colors.black54)),
      if (when.isNotEmpty)
        Text(when, style: const TextStyle(color: Colors.black54)),
    ]);
  }

  Widget _autoCard() {
    final auto = _st['auto'] == true;
    final note = (_st['autoNote'] as String?) ?? '';
    return _card([
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('অটো রিকানেক্ট'),
        subtitle: Text(_alive
            ? 'ব্যাকগ্রাউন্ড সার্ভিস চলছে।'
            : 'সার্ভিস সাড়া দিচ্ছে না, চালু করার চেষ্টা চলছে।'),
        value: _alive && auto,
        onChanged: _alive ? _toggleAuto : null,
      ),
      if (note.isNotEmpty) Text(note),
    ]);
  }

  Widget _attemptCard() {
    final seen = (_st['seen'] as List?)?.cast<dynamic>() ?? const [];
    final detail = (_st['lastDetail'] as String?) ?? '';
    final ok = _st['lastOk'];
    return _card([
      const Text('সর্বশেষ চেষ্টা',
          style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      Text((_st['lastAttempt'] as String?) ?? 'এখনো কোনো চেষ্টা হয়নি।',
          style: TextStyle(
              color: ok == true
                  ? Colors.green.shade800
                  : (ok == false ? Colors.red.shade800 : null))),
      if (seen.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('কালেক্টর যেসব Wi-Fi দেখেছে: ${seen.join(', ')}',
              style: const TextStyle(color: Colors.black54)),
        ),
      if (detail.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('বিবরণ: $detail',
              style: const TextStyle(color: Colors.black45, fontSize: 12)),
        ),
    ]);
  }

  Widget _credsCard() {
    return _card([
      const Text('Wi-Fi এর নাম ও পাসওয়ার্ড (একবার সেভ করুন)',
          style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      TextField(
        controller: _ssidC,
        decoration: const InputDecoration(
            labelText: 'Wi-Fi এর নাম (SSID)', border: OutlineInputBorder()),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _passC,
        obscureText: _obscure,
        decoration: InputDecoration(
          labelText: 'Wi-Fi পাসওয়ার্ড',
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ),
      ),
      const SizedBox(height: 8),
      FilledButton.tonal(onPressed: _save, child: const Text('সেভ করুন')),
      if (_saveInfo.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(_saveInfo, style: const TextStyle(color: Colors.black54)),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ইনভার্টার এক ট্যাপ')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          if (!_permsOk)
            _card([
              const Text(
                  'ব্লুটুথ, লোকেশন ও নোটিফিকেশন অনুমতি লাগবে। লোকেশন শুধু ব্লুটুথ স্ক্যানের জন্য, ফোন এটা Android নিয়মে চায়।'),
              const SizedBox(height: 8),
              FilledButton(
                  onPressed: _askPerms, child: const Text('অনুমতি দিন')),
            ]),
          _rangeCard(),
          _oneTapButton(),
          _workerCard(),
          _autoCard(),
          _attemptCard(),
          _credsCard(),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () =>
                    FlutterForegroundTask.sendDataToTask({'cmd': 'refresh'}),
                child: const Text('অবস্থা দেখো'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton(
                onPressed: () async {
                  await Permission.ignoreBatteryOptimizations.request();
                },
                child: const Text('ব্যাটারি অনুমতি'),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          const Text(
            'MIUI টিপ: Settings → Apps → Manage apps → এই অ্যাপ → Battery saver = No restrictions, আর Autostart চালু করুন। Recent apps এ অ্যাপটি লক করে রাখলে ভালো।',
            style: TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
