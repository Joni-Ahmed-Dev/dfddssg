import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';

import 'auto_reconnect.dart';
import 'ble_service.dart';
import 'config.dart';
import 'storage_service.dart';
import 'worker_status.dart';

void main() {
  // Lets the background auto-reconnect service talk to this UI.
  FlutterForegroundTask.initCommunicationPort();
  AutoReconnect.init();
  runApp(const OneTapApp());
}

class OneTapApp extends StatelessWidget {
  const OneTapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ইনভার্টার এক ট্যাপ',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _storage = CredentialStorage();
  final _ble = CollectorBleService();
  final _ssidController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _hasSaved = false;
  bool _busy = false;
  bool _found = false;
  String _status = 'শুরু করার আগে একবার ওয়াইফাই তথ্য সেভ করো।';

  // Auto reconnect state.
  bool _autoRunning = false;
  bool _autoBusy = false;
  String _autoDetail = 'অটো রিকানেক্ট বন্ধ আছে।';
  String _workerLine = 'Worker এর অবস্থা জানা নেই।';
  String _lastAttemptLine = '';

  @override
  void initState() {
    super.initState();
    FlutterForegroundTask.addTaskDataCallback(_onReceiveTaskData);
    _refreshSaved();
    _refreshAutoRunning();
    _refreshWorkerStatus();
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onReceiveTaskData);
    _ssidController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _onReceiveTaskData(Object data) {
    if (data is! Map<String, dynamic>) return;
    if (data['type'] != 'auto_status') return;
    if (!mounted) return;
    setState(() {
      _autoDetail = (data['detail'] as String?) ?? _autoDetail;
      final lastAttempt = data['lastAttempt'] as String?;
      final lastAttemptAt = data['lastAttemptAt'] as int?;
      if (lastAttempt != null && lastAttempt != 'none' && lastAttemptAt != null) {
        _lastAttemptLine =
            'শেষ চেষ্টা: ${_attemptLabel(lastAttempt)} ${_timeAgo(lastAttemptAt)}';
      }
      final lastDataTs = data['lastDataTs'] as int?;
      final lastState = data['lastState'] as String?;
      final lastVoltage = data['lastVoltage'];
      if (lastDataTs != null) {
        _workerLine = _workerLineFor(lastState, lastVoltage, lastDataTs);
      }
    });
  }

  String _attemptLabel(String attempt) {
    switch (attempt) {
      case 'success':
        return 'সফল হয়েছে';
      case 'not_near':
        return 'ফোন কাছে ছিল না';
      case 'failed':
        return 'হয়নি';
      case 'no_credentials':
        return 'ওয়াইফাই তথ্য সেভ নেই';
      default:
        return attempt;
    }
  }

  String _timeAgo(int epochMs) {
    final diff = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(epochMs),
    );
    if (diff.inSeconds < 60) return 'এইমাত্র';
    if (diff.inMinutes < 60) return '${diff.inMinutes} মিনিট আগে';
    return '${diff.inHours} ঘণ্টা আগে';
  }

  String _workerLineFor(String? lastState, Object? lastVoltage, int lastDataTs) {
    final age = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(lastDataTs),
    );
    final state = lastState == 'up'
        ? 'বিদ্যুৎ আছে'
        : lastState == 'down'
            ? 'বিদ্যুৎ নেই'
            : 'অবস্থা জানা নেই';
    final volt = lastVoltage is num ? '${lastVoltage.toStringAsFixed(0)}V' : '';
    final ageText = age.inSeconds < 60
        ? 'এইমাত্র'
        : age.inMinutes < 60
            ? '${age.inMinutes} মিনিট আগে'
            : '${age.inHours} ঘণ্টা আগে';
    final stale = age > WorkerStatus.staleAfter ? ' (ডেটা আসছে না)' : '';
    return '$state $volt, শেষ ডেটা $ageText$stale';
  }

  Future<void> _refreshSaved() async {
    final saved = await _storage.hasCredentials();
    final ssid = await _storage.readSsid();
    if (mounted) {
      setState(() {
        _hasSaved = saved;
        if (saved && ssid != null) _ssidController.text = ssid;
      });
    }
  }

  Future<void> _refreshAutoRunning() async {
    final running = await AutoReconnect.isRunning;
    if (mounted) {
      setState(() {
        _autoRunning = running;
        if (running && _autoDetail == 'অটো রিকানেক্ট বন্ধ আছে.') {
          _autoDetail = 'অটো রিকানেক্ট চালু আছে।';
        }
      });
    }
  }

  Future<void> _refreshWorkerStatus() async {
    final status = await fetchWorkerStatus();
    if (!mounted) return;
    setState(() {
      if (status == null) {
        _workerLine = 'Worker এর সাথে যোগাযোগ হয়নি।';
      } else if (status.lastDataTs == null) {
        _workerLine = 'ডেটা এখনো আসেনি।';
      } else {
        _workerLine = _workerLineFor(
          status.lastState,
          status.lastVoltage,
          status.lastDataTs!,
        );
      }
    });
  }

  Future<bool> _ensurePermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    return statuses.values.every((s) => s.isGranted);
  }

  Future<void> _save() async {
    final ssid = _ssidController.text.trim();
    final password = _passwordController.text;
    if (ssid.isEmpty || password.isEmpty) {
      setState(() => _status = 'নাম আর পাসওয়ার্ড দুটোই লাগবে।');
      return;
    }
    setState(() => _busy = true);
    await _storage.save(ssid, password);
    // Clear the password from memory as soon as it is stored.
    _passwordController.clear();
    await _refreshSaved();
    setState(() {
      _busy = false;
      _status = 'সেভ হয়েছে। পাসওয়ার্ড আর দেখানো হবে না, শুধু ফোনে থাকবে।';
    });
  }

  Future<void> _oneTap() async {
    if (!_hasSaved) {
      setState(() => _status = 'আগে ওয়াইফাই তথ্য সেভ করো।');
      return;
    }
    if (!await _ensurePermissions()) {
      setState(() => _status = 'ব্লুটুথ পারমিশন ছাড়া কাজ হবে না। পারমিশন দাও।');
      return;
    }
    setState(() {
      _busy = true;
      _found = false;
      _status = 'কালেক্টর খুঁজছি। ইনভার্টারের কাছে থাকো।';
    });
    try {
      final found = await _ble.scanForCollector();
      if (!found) {
        setState(() => _status = 'কালেক্টর পাওয়া যায়নি। কাছে গিয়ে আবার চেষ্টা করো।');
        return;
      }
      setState(() {
        _found = true;
        _status = 'কালেক্টর পাওয়া গেছে। সেভ করা তথ্য পাঠাচ্ছি।';
      });
      final ssid = await _storage.readSsid();
      final password = await _storage.readPassword();
      if (ssid == null || password == null) {
        setState(() => _status = 'সেভ করা তথ্য পাওয়া যায়নি। আবার সেভ করো।');
        return;
      }
      await _ble.provision(ssid, password);
      setState(() => _status =
          'পাঠানো হয়েছে। ২ মিনিট অপেক্ষা করো, তারপর Things-X এ অনলাইন দেখো।');
    } catch (e) {
      setState(() => _status = 'হয়নি: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleAuto(bool enable) async {
    if (_autoBusy) return;
    setState(() => _autoBusy = true);
    try {
      if (enable) {
        if (!_hasSaved) {
          setState(() {
            _autoDetail = 'আগে ওয়াইফাই তথ্য সেভ করো, তারপর অটো চালু করো।';
            _autoRunning = false;
          });
          return;
        }
        if (!await _ensurePermissions()) {
          setState(() {
            _autoDetail = 'ব্লুটুথ পারমিশন ছাড়া অটো চলবে না। পারমিশন দাও।';
            _autoRunning = false;
          });
          return;
        }
        await AutoReconnect.requestPermissions();
        final result = await AutoReconnect.start();
        final running = await AutoReconnect.isRunning;
        setState(() {
          _autoRunning = running;
          _autoDetail = running
              ? 'অটো রিকানেক্ট চালু হয়েছে। ডেটা বন্ধ হলে নিজে থেকে আবার যুক্ত করবে।'
              : 'অটো চালু হয়নি: $result';
        });
      } else {
        await AutoReconnect.stop();
        setState(() {
          _autoRunning = false;
          _autoDetail = 'অটো রিকানেক্ট বন্ধ আছে।';
        });
      }
    } catch (e) {
      setState(() => _autoDetail = 'অটো চালু/বন্ধ করতে সমস্যা: $e');
    } finally {
      if (mounted) setState(() => _autoBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ইনভার্টার এক ট্যাপ')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _hasSaved ? 'ওয়াইফাই তথ্য সেভ আছে।' : 'ওয়াইফাই তথ্য এখনো সেভ হয়নি।',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text('কালেক্টর: ${CollectorConfig.collectorMac}'),
            const SizedBox(height: 16),
            TextField(
              controller: _ssidController,
              decoration: const InputDecoration(
                labelText: 'ওয়াইফাই নাম',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'ওয়াইফাই পাসওয়ার্ড',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('একবার সেভ করো'),
            ),
            const SizedBox(height: 24),
            FilledButton.tonal(
              onPressed: _busy ? null : _oneTap,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 20),
              ),
              child: const Text(
                'এক ট্যাপে আবার যুক্ত করো',
                style: TextStyle(fontSize: 18),
              ),
            ),
            const SizedBox(height: 16),
            if (_busy) const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text(_status),
            if (_found) const SizedBox(height: 8),
            if (_found) const Text('কালেক্টর এই মুহূর্তে ব্লুটুথে দেখা গেছে।'),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 8),
            Text(
              'অটো রিকানেক্ট',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text(
              'চালু থাকলে ডেটা বন্ধ হলেই অ্যাপ নিজে থেকে বারবার যুক্ত করার চেষ্টা করবে। আর কোনো পারমিশন বা ট্যাপ লাগবে না।',
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              title: const Text('অটো রিকানেক্ট চালু'),
              value: _autoRunning,
              onChanged: _autoBusy ? null : _toggleAuto,
              contentPadding: EdgeInsets.zero,
            ),
            Text(_autoDetail),
            if (_lastAttemptLine.isNotEmpty) const SizedBox(height: 4),
            if (_lastAttemptLine.isNotEmpty) Text(_lastAttemptLine),
            const SizedBox(height: 12),
            Text(_workerLine),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _refreshWorkerStatus,
                    child: const Text('অবস্থা দেখো'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : _oneTap,
                    child: const Text('এখনই চেষ্টা করো'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'মনে রাখো: ফোন ইনভার্টারের কাছে না থাকলে এই বোতাম কাজ করবে না। '
              'অটো চালু রাখতে ব্যাটারি সেটিংসে এই অ্যাপে No restrictions দাও আর Autostart চালু করো, নাহলে ফোন ব্যাকগ্রাউন্ডে অ্যাপ বন্ধ করে দিতে পারে।',
            ),
          ],
        ),
      ),
    );
  }
}
