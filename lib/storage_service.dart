import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Wi-Fi credentials live only on this phone, in encrypted storage.
/// They are never sent to Muse, never sent to any server by this app,
/// and never printed to logs. The UI only ever shows "saved" or "not saved".
class CredentialStorage {
  static const _ssidKey = 'collector_wifi_ssid';
  static const _passwordKey = 'collector_wifi_password';
  static const _storage = FlutterSecureStorage();

  Future<void> save(String ssid, String password) async {
    await _storage.write(key: _ssidKey, value: ssid);
    await _storage.write(key: _passwordKey, value: password);
  }

  Future<String?> readSsid() => _storage.read(key: _ssidKey);

  Future<String?> readPassword() => _storage.read(key: _passwordKey);

  Future<bool> hasCredentials() async {
    final ssid = await readSsid();
    final password = await readPassword();
    return ssid != null && ssid.isNotEmpty && password != null && password.isNotEmpty;
  }

  Future<void> clear() async {
    await _storage.delete(key: _ssidKey);
    await _storage.delete(key: _passwordKey);
  }
}
