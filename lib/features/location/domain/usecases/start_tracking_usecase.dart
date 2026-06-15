import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'package:permission_handler/permission_handler.dart' as ph;

import '../../../../core/utils/app_logger.dart';
import '../repositories/location_repository.dart';
import '../entities/driver_location.dart';

/// Result returned to the caller when [StartTrackingUseCase] is invoked.
/// The UI layer uses this to decide what dialog / action to present.
enum TrackingStartResult {
  /// Tracking started successfully.
  started,

  /// Location services are disabled — user must enable GPS in device Settings.
  locationServicesDisabled,

  /// Permission permanently denied — must redirect to app Settings.
  permissionPermanentlyDenied,

  /// User denied location permission.
  permissionDenied,

  /// Only foreground ("While Using App") was granted.
  /// Tracking can start but background tracking will not work.
  /// Show a dialog and then redirect to app Settings.
  backgroundPermissionMissing,
}

class StartTrackingUseCase {
  final LocationRepository _repository;

  StartTrackingUseCase(this._repository);

  Future<TrackingStartResult> call(String tripId) async {
    // ── Step 1: Location services ────────────────
    try {
      final state = await bg.BackgroundGeolocation.providerState;
      if (!state.enabled) {
        AppLogger.locationServicesDisabled();
        return TrackingStartResult.locationServicesDisabled;
      }
    } catch (e) {
      AppLogger.warn('START_TRACKING', 'providerState check failed: $e');
    }

    // ── Step 2: Foreground location permission ─────────────────────────────
    var status = await ph.Permission.location.status;

    if (status.isPermanentlyDenied) {
      AppLogger.permissionPermanentlyDenied('location');
      return TrackingStartResult.permissionPermanentlyDenied;
    }

    if (!status.isGranted) {
      status = await ph.Permission.location.request();
    }

    if (!status.isGranted) {
      if (status.isPermanentlyDenied) {
        AppLogger.permissionPermanentlyDenied('location');
        return TrackingStartResult.permissionPermanentlyDenied;
      }
      AppLogger.permissionDenied('location');
      return TrackingStartResult.permissionDenied;
    }

    AppLogger.permissionGranted('location.whileInUse');

    // ── Step 3: Background ("always") permission ───────────────────────────
    // Required so tracking continues when the screen is locked.
    final bgStatus = await ph.Permission.locationAlways.status;

    if (!bgStatus.isGranted) {
      final requested = await ph.Permission.locationAlways.request();
      if (!requested.isGranted) {
        AppLogger.backgroundPermissionRequired();
        // Return early — caller shows the "Allow All The Time" dialog and
        // redirects to Settings.  Do NOT start tracking without it.
        return TrackingStartResult.backgroundPermissionMissing;
      }
    }

    AppLogger.backgroundPermissionGranted();

    // ── Step 4: Android 13+ notification permission ────────────────────────
    // Needed for the foreground service notification.
    await ph.Permission.notification.request();

    // ── Step 5: Start tracking ─────────────────────────────────────────────
    await _repository.startTracking(tripId);
    AppLogger.tripStarted(tripId);
    return TrackingStartResult.started;
  }
}

class GetLocationStreamUseCase {
  final LocationRepository _repository;
  GetLocationStreamUseCase(this._repository);

  Stream<DriverLocation> call() => _repository.locationStream;
}
