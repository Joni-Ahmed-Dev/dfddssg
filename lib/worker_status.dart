import 'dart:convert';

import 'package:http/http.dart' as http;

/// Reads the Cloudflare Worker status endpoint and tells whether the
/// inverter data is flowing. This is the same condition the Worker uses
/// for its "data not coming" warning: no new inverter data for 5 minutes.
class WorkerStatus {
  static const String statusUrl =
      'https://grid-alert.aminuljoni180.workers.dev/fast-status';

  /// Same threshold as the Worker (STALE_MS = 5 minutes).
  static const Duration staleAfter = Duration(minutes: 5);

  /// "up", "down" or "unknown".
  final String lastState;

  /// Last grid voltage, null when unknown.
  final double? lastVoltage;

  /// Epoch milliseconds of the last inverter data, null when unknown.
  final int? lastDataTs;

  const WorkerStatus({
    required this.lastState,
    required this.lastVoltage,
    required this.lastDataTs,
  });

  /// True when the inverter data has not arrived for [staleAfter].
  /// This is exactly when the Worker sends its
  /// "⚠️ ইনভার্টারের ডেটা আসছে না" warning.
  bool get isStale {
    if (lastDataTs == null) return true;
    final age = DateTime.now().millisecondsSinceEpoch - lastDataTs!;
    return age > staleAfter.inMilliseconds;
  }

  /// How long since the last inverter data, null when unknown.
  Duration? get dataAge {
    if (lastDataTs == null) return null;
    final ms = DateTime.now().millisecondsSinceEpoch - lastDataTs!;
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  static WorkerStatus? fromJson(Map<String, dynamic> json) {
    final rawTs = json['lastDataTs'];
    final rawV = json['lastVoltage'];
    return WorkerStatus(
      lastState: (json['lastState'] as String?) ?? 'unknown',
      lastVoltage: rawV is num ? rawV.toDouble() : null,
      lastDataTs: rawTs is num ? rawTs.toInt() : null,
    );
  }
}

/// Fetches the Worker status. Returns null when the request fails
/// (no internet, Worker unreachable). A null result means "unknown",
/// never "stale": the app only acts when it positively sees stale data.
Future<WorkerStatus?> fetchWorkerStatus() async {
  try {
    final response = await http
        .get(Uri.parse(WorkerStatus.statusUrl))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;
    return WorkerStatus.fromJson(decoded);
  } catch (_) {
    return null;
  }
}
