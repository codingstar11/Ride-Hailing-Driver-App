import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:logger/logger.dart';

import '../storage/hive_storage.dart';
import '../utils/app_logger.dart';
import 'background_service_handler.dart';

/// Handles device reboot recovery for active tracking sessions.
///
/// When the device reboots while a trip is active, Android kills all
/// processes including foreground services.  Without recovery logic the
/// driver's trip silently stops — GPS data is lost until the driver
/// manually reopens the app and presses Start Trip again.
///
/// Recovery strategy
/// ─────────────────
/// 1. The active trip ID is already persisted in the Hive 'active_trip' box
///    by [LocationHiveDatasource.saveActiveTrip].
/// 2. This class provides [onBootCompleted], registered as a
///    `@pragma('vm:entry-point')` callback so it can be invoked from a
///    platform-side BroadcastReceiver that listens for
///    `android.intent.action.BOOT_COMPLETED`.
/// 3. On boot, [onBootCompleted] opens Hive, checks for an active trip,
///    and if one exists it restarts the background GPS service so tracking
///    resumes automatically.
/// 4. The next time the driver opens the app, [TripRestorationRequested]
///    in [LocationBloc] reconnects the UI to the already-running service.


/// iOS
/// iOS does not support BOOT_COMPLETED equivalents. The app is relaunched
/// by significant-location-change events when the device moves after reboot.
class BootReceiver {
  static final _logger = Logger();

  /// Entry point called by the platform BootReceiver after BOOT_COMPLETED.
  ///
  /// Must be annotated with `@pragma('vm:entry-point')` so the Dart AOT
  /// compiler does not tree-shake it away in release builds.
  @pragma('vm:entry-point')
  static Future<void> onBootCompleted() async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();

    _logger
        .i('[BootReceiver] BOOT_COMPLETED received — checking for active trip');

    try {
      // Open Hive so we can read the persisted active trip.
      await HiveStorage.initialise();

      final activeTripData = HiveStorage.activeTrip.get('current');
      final tripId = activeTripData?['trip_id'] as String?;

      if (tripId == null) {
        _logger.i('[BootReceiver] No active trip found — nothing to restore');
        return;
      }

      _logger.i('[BootReceiver] Active trip found after reboot  trip=$tripId  '
          'started_at=${activeTripData?['started_at']}');

      AppLogger.info('BOOT_RECEIVER',
          'Restarting background service for trip=$tripId after device reboot');

      // Re-initialise and restart the background service so GPS collection
      // resumes without requiring the driver to open the app.
      await BackgroundServiceHandler.initialize();
      await BackgroundServiceHandler.startService();

      _logger.i('[BootReceiver] Background service restarted successfully');
    } catch (e, stack) {
      _logger.e(
          '[BootReceiver] Failed to restore tracking after reboot  $e\n$stack');
    }
  }

  /// Checks whether a reboot recovery should be triggered.
  /// Call this from main() after HiveStorage.initialise() to handle the
  /// case where flutter_background_service did NOT auto-restart the service.
  static Future<bool> checkAndRestoreIfNeeded() async {
    try {
      final activeTripData = HiveStorage.activeTrip.get('current');
      final tripId = activeTripData?['trip_id'] as String?;
      if (tripId == null) return false;

      // Check if the background service is already running.
      final isRunning = await FlutterBackgroundService().isRunning();
      if (isRunning) {
        _logger.i(
            '[BootReceiver] Service already running for trip=$tripId — no recovery needed');
        return false;
      }

      _logger.i(
          '[BootReceiver] Service not running but trip is active  trip=$tripId  '
          '— restarting after possible reboot or process kill');

      await BackgroundServiceHandler.startService();
      return true;
    } catch (e) {
      _logger.w('[BootReceiver] Recovery check failed: $e');
      return false;
    }
  }
}
