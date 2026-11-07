import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class Creds {
  final String ssid;
  final String pass;
  const Creds(this.ssid, this.pass);
}

class Storage {
  static const FlutterSecureStorage _s = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// শুরু/শেষের স্পেস, অদৃশ্য অক্ষর ও NBSP বাদ দেয়।
  static String clean(String v) {
    return v
        .replaceAll('\u00A0', ' ')
        .replaceAll(RegExp('[\u200B-\u200F\u202A-\u202E\u2060\uFEFF]'), '')
        .trim();
  }

  static Future<void> saveCreds(String ssid, String pass) async {
    await _s.write(key: 'collector_wifi_ssid', value: clean(ssid));
    await _s.write(key: 'collector_wifi_password', value: clean(pass));
  }

  static Future<Creds> loadCreds() async {
    final a = await _s.read(key: 'collector_wifi_ssid') ?? '';
    final b = await _s.read(key: 'collector_wifi_password') ?? '';
    return Creds(clean(a), clean(b));
  }

  static Future<void> saveAuto(bool v) async {
    await _s.write(key: 'auto_enabled', value: v ? '1' : '0');
  }

  static Future<bool> loadAuto() async {
    final v = await _s.read(key: 'auto_enabled');
    return v != '0'; // না থাকলে ডিফল্ট চালু
  }
}
