import 'dart:io';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'package:permission_handler/permission_handler.dart' as ph;

import '../utils/app_logger.dart';

/// Result of a permission check/request cycle.
enum PermissionResult {
  /// Full background ("Always") permission — tracking can start.
  granted,

  /// Only foreground ("While Using App") granted — background not available.
  foregroundOnly,

  /// Location services are turned off in device Settings.
  serviceDisabled,

  /// User explicitly denied or permanently denied.
  denied,

  /// User permanently denied and must go to Settings manually.
  permanentlyDenied,
}

class PermissionService {
  /// Checks permissions without prompting. Returns the current result.
  static Future<PermissionResult> check() async {
    try {
      final state = await bg.BackgroundGeolocation.providerState;

      if (!state.enabled) {
        AppLogger.locationServicesDisabled();
        return PermissionResult.serviceDisabled;
      }

      // status: 0=NotDetermined 1=Restricted 2=Denied 3=Always 4=WhenInUse
      switch (state.status) {
        case bg.ProviderChangeEvent.AUTHORIZATION_STATUS_ALWAYS:
          return PermissionResult.granted;
        case bg.ProviderChangeEvent.AUTHORIZATION_STATUS_WHEN_IN_USE:
          return PermissionResult.foregroundOnly;
        case bg.ProviderChangeEvent.AUTHORIZATION_STATUS_DENIED:
          return PermissionResult.permanentlyDenied;
        default:
          return PermissionResult.denied;
      }
    } catch (e) {
      AppLogger.warn('PERMISSION', 'providerState check failed: $e');
      return PermissionResult.denied;
    }
  }

  static Future<PermissionResult> request() async {
    // Step 1 — foreground location via permission_handler.
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

    // Step 2 — Android 13+ notification permission.
    if (Platform.isAndroid) {
      await ph.Permission.notification.request();
    }

    // Step 3 — background ("always") location.
    final bgStatus = await ph.Permission.locationAlways.request();

    if (bgStatus.isGranted) {
      AppLogger.backgroundPermissionGranted();

      // Step 4 — Android battery optimisation opt-out.
      if (Platform.isAndroid) {
        final batteryStatus =
            await ph.Permission.ignoreBatteryOptimizations.status;
        if (!batteryStatus.isGranted) {
          await ph.Permission.ignoreBatteryOptimizations.request();
        }

        // Step 5 — Activity recognition for motion detection.
        final motionStatus =
            await ph.Permission.activityRecognition.status;
        if (!motionStatus.isGranted) {
          await ph.Permission.activityRecognition.request();
        }
      }
      return PermissionResult.granted;
    }

    AppLogger.backgroundPermissionRequired();
    return PermissionResult.foregroundOnly;
  }

  /// Opens the app's Settings page so the user can manually upgrade to
  /// "Allow All The Time" (iOS) or "Allow all the time" (Android).
  static Future<void> openAppSettings() => ph.openAppSettings();

  /// Opens the device's Location settings page so the user can enable GPS.
  /// Falls back to app settings if the platform doesn't support direct
  /// location settings navigation.
  static Future<void> openLocationSettings() => ph.openAppSettings();
}