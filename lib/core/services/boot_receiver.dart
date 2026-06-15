import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/hive_storage.dart';
import '../utils/app_logger.dart';

class BootReceiver {
  static final _logger = Logger();
  static Future<bool> checkAndRestoreIfNeeded() async {
    try {
      // Primary: Hive
      final activeTripData = HiveStorage.activeTrip.get('current');
      final tripIdFromHive = activeTripData?['trip_id'] as String?;

      if (tripIdFromHive != null && tripIdFromHive.isNotEmpty) {
        _logger.i('[BootReceiver] Active trip found in Hive: $tripIdFromHive '
            '— restoration will be handled by LocationBloc');
        AppLogger.info('BOOT_RECEIVER',
            'Active trip detected (Hive)  trip=$tripIdFromHive — awaiting BLoC restoration');
        return true;
      }

      // Fallback: SharedPreferences (in case Hive box was not yet open)
      final prefs = await SharedPreferences.getInstance();
      final tripIdFromPrefs = prefs.getString('active_trip_id');

      if (tripIdFromPrefs != null && tripIdFromPrefs.isNotEmpty) {
        _logger.i(
            '[BootReceiver] Active trip found in SharedPreferences: $tripIdFromPrefs '
            '— Hive not yet initialized at check time');
        AppLogger.info('BOOT_RECEIVER',
            'Active trip detected (SharedPreferences fallback)  trip=$tripIdFromPrefs');
        return true;
      }

      AppLogger.info(
          'BOOT_RECEIVER', 'No active trip found — no recovery needed');
      return false;
    } catch (e) {
      _logger.w('[BootReceiver] Recovery check failed: $e');
      return false;
    }
  }
}
