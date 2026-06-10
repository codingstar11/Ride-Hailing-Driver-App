class AppConstants {

  static const String baseUrl = ''; // Intentionally empty — Mock API/firebase is used
  static const double initialLatitude = 33.5232835;
  static const double initialLongitude = 71.4433168;

  // ── Tracking ─────────────────────────────────────────────────────────────
  static const int locationIntervalSeconds = 5;
  static const double locationDistanceMeters = 20.0;
  static const double minAccuracyMeters = 50.0;
  static const int maxRetryCount = 5; // Increased from 3 for production safety
  static const int batchUploadSize = 50;

  // ── Notifications ─────────────────────────────────────────────────────────
  static const int trackingNotificationId = 1001;
  static const String trackingChannelId = 'location_tracking';
  static const String trackingChannelName = 'Location Tracking';

  // ── Background service ────────────────────────────────────────────────────
  static const String bgServiceAction = 'com.ridehailing.driver.LOCATION_UPDATE';

  // ── Hive storage ──────────────────────────────────────────────────────────
  static const int uploadedRecordRetentionDays = 7;
  static const int maxTelemetryEntries = 5000; // Prune when exceeded

  // ── Telemetry event names ─────────────────────────────────────────────────
  static const String evtLocationSaved = 'location_saved';
  static const String evtLocationUploaded = 'location_uploaded';
  static const String evtServiceStarted = 'service_started';
  static const String evtServiceKilled = 'service_killed';
  static const String evtTripStarted = 'trip_started';
  static const String evtTripEnded = 'trip_ended';
  static const String evtConnectivityRestored = 'connectivity_restored';
  static const String evtUploadFailed = 'upload_failed';
}
