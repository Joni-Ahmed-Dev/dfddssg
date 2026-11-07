import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config.dart';

enum DataHealth { fresh, stale, workerUnreachable, workerCloudError, unknown }

class WorkerSnapshot {
  final DataHealth health;
  final int? ageSec;
  final int errorCount;
  final String? state;
  final double? voltage;
  final String text;

  const WorkerSnapshot({
    required this.health,
    required this.text,
    this.ageSec,
    this.errorCount = 0,
    this.state,
    this.voltage,
  });

  Map<String, dynamic> toMap() => {
        'health': health.name,
        'ageSec': ageSec,
        'errorCount': errorCount,
        'state': state,
        'voltage': voltage,
        'text': text,
      };
}

class WorkerStatus {
  static String _dur(int sec) {
    if (sec < 90) return '$sec সেকেন্ড';
    return '${(sec / 60).round()} মিনিট';
  }

  static Future<WorkerSnapshot> fetch({int? prevErrorCount}) async {
    try {
      final r = await http
          .get(Uri.parse(Cfg.workerUrl))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) {
        return const WorkerSnapshot(
          health: DataHealth.workerUnreachable,
          text: 'Worker এর সাথে যোগাযোগ হয়নি।',
        );
      }
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is! Map) {
        return const WorkerSnapshot(
          health: DataHealth.workerUnreachable,
          text: 'Worker এর উত্তর বোঝা যায়নি।',
        );
      }
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final lastData = (j['lastDataTs'] as num?)?.toInt();
      final lastCheck = (j['lastCheckTs'] as num?)?.toInt();
      final err = (j['errorCount'] as num?)?.toInt() ?? 0;
      final state = j['lastState']?.toString();
      final volt = double.tryParse('${j['lastVoltage']}');

      if (lastData == null) {
        return WorkerSnapshot(
          health: DataHealth.unknown,
          text: 'Worker এখনো কোনো ডেটার সময় জানায়নি।',
          errorCount: err,
          state: state,
          voltage: volt,
        );
      }
      final age = ((nowMs - lastData) / 1000).round();
      final stale = age > Cfg.staleAfter.inSeconds;

      if (!stale) {
        return WorkerSnapshot(
          health: DataHealth.fresh,
          text: 'ডেটা ঠিক আছে (${_dur(age < 0 ? 0 : age)} আগে এসেছে)।',
          ageSec: age,
          errorCount: err,
          state: state,
          voltage: volt,
        );
      }

      final checkAge =
          lastCheck == null ? null : ((nowMs - lastCheck) / 1000).round();
      final workerNotChecking = checkAge != null && checkAge > 180;
      final errorsRising = prevErrorCount != null && err > prevErrorCount;
      if (workerNotChecking || errorsRising) {
        return WorkerSnapshot(
          health: DataHealth.workerCloudError,
          text:
              'Worker নিজে Things-X ক্লাউডে পৌঁছাতে পারছে না (ত্রুটি গুনতি $err)। কালেক্টর অফলাইন কিনা এখান থেকে বলা যাচ্ছে না।',
          ageSec: age,
          errorCount: err,
          state: state,
          voltage: volt,
        );
      }
      return WorkerSnapshot(
        health: DataHealth.stale,
        text: 'ডেটা পুরনো — ${_dur(age)} ধরে নতুন ডেটা নেই।',
        ageSec: age,
        errorCount: err,
        state: state,
        voltage: volt,
      );
    } catch (_) {
      return const WorkerSnapshot(
        health: DataHealth.workerUnreachable,
        text: 'Worker এর সাথে যোগাযোগ হয়নি (ইন্টারনেট ধীর বা বন্ধ হতে পারে)।',
      );
    }
  }
}
