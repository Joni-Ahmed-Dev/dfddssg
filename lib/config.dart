import 'dart:convert';
import 'dart:typed_data';

/// BLE configuration for the TAHU collector.
///
/// IMPORTANT: Do not guess these values. Fill them in only after analysing
/// the Bluetooth HCI snoop log from one normal Things-X Wi-Fi setup.
/// Until [payloadMode] is set to a real mode, the app refuses to provision
/// and tells the user exactly what is missing. That is deliberate:
/// sending the wrong bytes could put the collector in a bad state.
class CollectorConfig {
  /// Default collector MAC from the project notes. Change it here if
  /// nRF Connect shows a different MAC for your collector.
  static const String collectorMac = '80:6A:34:4E:DA:6F';

  /// TODO: fill from the HCI snoop log.
  static const String serviceUuid = 'TODO_FROM_SNOOP_LOG';
  static const String characteristicUuid = 'TODO_FROM_SNOOP_LOG';

  /// Set this to 'plain' or 'json' only after the snoop log shows the
  /// real format. Keep it as 'todo' until then.
  static const String payloadMode = 'todo';

  /// Builds the bytes to write, once the format is known.
  /// Never log or print the returned bytes: they contain the password.
  static Uint8List buildPayload(String ssid, String password) {
    switch (payloadMode) {
      case 'plain':
        // Example only. Replace the separator with the exact one
        // seen in the snoop log, for example \n, \0, or a length prefix.
        return Uint8List.fromList(utf8.encode('$ssid\n$password'));
      case 'json':
        // Example only. Replace the keys with the exact keys seen
        // in the snoop log.
        return Uint8List.fromList(
          utf8.encode(jsonEncode({'ssid': ssid, 'password': password})),
        );
      default:
        throw StateError(
          'BLE payload format is not known yet. '
          'Analyse the HCI snoop log first and set payloadMode.',
        );
    }
  }
}
