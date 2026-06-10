import 'dart:io';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../utils/app_logger.dart';

/// Result of a permission check/request cycle.
enum PermissionResult {
  /// Full background ("Always") permission — tracking can start.
  granted,

  /// Only foreground ("While Using App") granted — background not available.
  /// On iOS the app can still run, but tracking will stop after ~170 s when
  /// the screen is locked. On Android the foreground service may be killed.
  foregroundOnly,

  /// Location services are turned off in device Settings.
  serviceDisabled,

  /// User explicitly denied or permanently denied.
  denied,

  /// User permanently denied and must go to Settings manually.
  permanentlyDenied,
}

class PermissionService {
  /// Checks permissions without prompting.  Returns the current result.
  static Future<PermissionResult> check() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      AppLogger.locationServicesDisabled();
      return PermissionResult.serviceDisabled;
    }

    final status = await ph.Permission.location.status;
    if (status.isDenied || status.isRestricted) {
      return PermissionResult.denied;
    }
    if (status.isPermanentlyDenied) {
      return PermissionResult.permanentlyDenied;
    }
    // Foreground granted — check background.
    final bgStatus = await ph.Permission.locationAlways.status;
    if (bgStatus.isGranted) {
      return PermissionResult.granted;
    }
    return PermissionResult.foregroundOnly;
  }
  
  static Future<PermissionResult> request() async {
    // Step 1 — location services.
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      AppLogger.locationServicesDisabled();
      return PermissionResult.serviceDisabled;
    }
    // Step 2 — foreground location.
    var status = await ph.Permission.location.status;
    if (status.isPermanentlyDenied) {
      AppLogger.permissionPermanentlyDenied('location');
      return PermissionResult.permanentlyDenied;
    }
    if (!status.isGranted) {
      status = await ph.Permission.location.request();
    }
    if (!status.isGranted) {
      if (status.isPermanentlyDenied) {
        AppLogger.permissionPermanentlyDenied('location');
        return PermissionResult.permanentlyDenied;
      }
      AppLogger.permissionDenied('location');
      return PermissionResult.denied;
    }
    AppLogger.permissionGranted('location.whileInUse');
    // Step 3 — Android 13+ notification permission (needed for foreground
    //          service notification on Android 13+).
    if (Platform.isAndroid) {
      await ph.Permission.notification.request();
    }
    // Step 4 — background ("always") location.
    // On iOS: the user must go to Settings after granting "While In Use".
    // On Android 10+: a separate system dialog appears.
    final bgStatus = await ph.Permission.locationAlways.request();

    if (bgStatus.isGranted) {
      AppLogger.backgroundPermissionGranted();
      // Step 5 — Android battery optimization opt-out.
      // Without this, Xiaomi/MIUI and other aggressive OEMs will kill the
      // foreground service after ~15 minutes, stopping location tracking.
      if (Platform.isAndroid) {
        final batteryStatus =
            await ph.Permission.ignoreBatteryOptimizations.status;
        if (!batteryStatus.isGranted) {
          await ph.Permission.ignoreBatteryOptimizations.request();
        }
      }
      return PermissionResult.granted;
    }

    // User granted foreground but not background.
    AppLogger.backgroundPermissionRequired();
    return PermissionResult.foregroundOnly;
  }

  /// Opens the app's Settings page so the user can manually upgrade to
  /// "Allow All The Time" (iOS) or "Allow all the time" (Android).
  static Future<void> openAppSettings() => ph.openAppSettings();

  /// Opens the device's Location services (GPS) settings page directly.
  static Future<void> openLocationSettings() => Geolocator.openLocationSettings();
}
