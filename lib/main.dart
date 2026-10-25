import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ble_service.dart';
import 'config.dart';
import 'storage_service.dart';

void main() => runApp(const OneTapApp());

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

  @override
  void initState() {
    super.initState();
    _refreshSaved();
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
            const Text(
              'মনে রাখো: ফোন ইনভার্টারের কাছে না থাকলে এই বোতাম কাজ করবে না। '
              'আর প্রোটোকল না জানা পর্যন্ত অ্যাপ নিজে জানিয়ে দেবে কী বাকি আছে।',
            ),
          ],
        ),
      ),
    );
  }
}
