import 'dart:convert';
import 'dart:typed_data';

/// BLE configuration for the TAHU collector.
///
/// Filled from the Bluetooth HCI snoop log of 2026-11-06 (two complete
/// Things-X Wi-Fi setups, handles 3 and 4). Full analysis:
/// workspace/solar-inverter/btsnoop-analysis-2026-11-06.md
///
/// Protocol: plain ASCII text commands, no pairing, no encryption.
///  - Scan channel 0xFF97: write "scanwifi" / "getwifi", results arrive
///    as JSON indications.
///  - Command channel 0xFF99: write "WIFI_SET <SSID> <password>".
///  - Responses arrive as JSON indications on 0xFF22, e.g.
///    {"code":0,"msg":"wifi *** OK! OK! ***","cmd":"wifi_set"}.
class CollectorConfig {
  /// BLE MAC seen in the HCI logs, advertising as
  /// TH1921162N0B260600161. Note: this is 1 higher than the Wi-Fi MAC
  /// ending 6F recorded earlier; BLE and Wi-Fi MACs often differ by 1.
  /// The app scans BLE, so it must use this BLE MAC.
  static const String collectorMac = '80:6A:34:4E:DA:70';

  /// Service 0xFFFF (16-bit) as a 128-bit Bluetooth base UUID.
  /// Holds the scan channel 0xFF97 and the command channel 0xFF99.
  static const String serviceUuid = '0000ffff-0000-1000-8000-00805f9b34fb';

  /// Command channel, char 0xFF99, value handle 0x001E.
  /// Write "WIFI_SET <SSID> <password>" here (Write Request).
  static const String characteristicUuid = '0000ff99-0000-1000-8000-00805f9b34fb';

  /// Wi-Fi scan channel, char 0xFF97, value handle 0x0021.
  /// Write "scanwifi" / "getwifi" here; results arrive as indications.
  static const String scanCharacteristicUuid = '0000ff97-0000-1000-8000-00805f9b34fb';

  /// Service 0xFF20 (16-bit) as a 128-bit Bluetooth base UUID.
  /// Holds the response channel 0xFF22.
  static const String responseServiceUuid = '0000ff20-0000-1000-8000-00805f9b34fb';

  /// Response channel, char 0xFF22, value handle 0x0010.
  /// Indications here carry the JSON replies, e.g. the wifi_set result.
  static const String responseCharacteristicUuid = '0000ff22-0000-1000-8000-00805f9b34fb';

  /// Payload format, as seen in the snoop log.
  static const String payloadMode = 'wifiset';

  /// Builds the bytes to write, once the format is known.
  /// Never log or print the returned bytes: they contain the password.
  static Uint8List buildPayload(String ssid, String password) {
    // Exact format seen in the snoop log: WIFI_SET <SSID> <password>.
    // Trim both: an invisible leading or trailing space (from a paste
    // or a keyboard) would make the collector look for a network that
    // does not exist, or fail the password, and answer NO.
    final cleanSsid = ssid.trim();
    final cleanPassword = password.trim();
    return Uint8List.fromList(
      utf8.encode('WIFI_SET $cleanSsid $cleanPassword'),
    );
  }
}
