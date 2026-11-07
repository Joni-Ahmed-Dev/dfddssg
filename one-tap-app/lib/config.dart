class Cfg {
  static const collectorMac = '80:6A:34:4E:DA:70';
  static const workerUrl =
      'https://grid-alert.aminuljoni180.workers.dev/fast-status';

  // ডেটা এর বেশি পুরনো হলে stale
  static const staleAfter = Duration(minutes: 2);
  // এই সময়ের মধ্যে কালেক্টরের বিজ্ঞাপন দেখা গেলে "কাছে আছে"
  static const rangeWindow = Duration(seconds: 10);
  // দুই provision চেষ্টার মধ্যে ন্যূনতম বিরতি
  static const provisionCooldown = Duration(minutes: 3);
  // provision এর পর ডেটা ফিরেছে কিনা দেখার আগে অপেক্ষা
  static const confirmWait = Duration(seconds: 60);
  // Worker চেক করার ব্যবধান
  static const tickEvery = Duration(minutes: 1);
}
