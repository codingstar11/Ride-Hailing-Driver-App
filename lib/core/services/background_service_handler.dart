import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../constants/app_constants.dart';
import '../storage/location_entry.dart';
import '../storage/telemetry_entry.dart';
import '../utils/app_logger.dart';
import '../../firebase_options.dart';

class BackgroundServiceHandler {
  static final _logger = Logger();

  // ── Broadcast stream controllers ─────────────────────────────────────────
  // These only exist in the main Dart isolate. The headless task runs in a
  // completely separate process and must NOT reference these.
  static final _locationController =
      StreamController<Map<String, dynamic>>.broadcast();
  static final _heartbeatController =
      StreamController<Map<String, dynamic>>.broadcast();
  static final _accuracyController =
      StreamController<Map<String, dynamic>>.broadcast();
  static final _errorController =
      StreamController<Map<String, dynamic>>.broadcast();

  static bool _initialized = false;

  // ── Public streams ────────────────────────────────────────────────────────

  static Stream<Map<String, dynamic>?> get locationStream =>
      _locationController.stream;

  static Stream<Map<String, dynamic>?> get heartbeatStream =>
      _heartbeatController.stream;

  static Stream<Map<String, dynamic>?> get accuracyIssueStream =>
      _accuracyController.stream;

  static Stream<Map<String, dynamic>?> get errorStream =>
      _errorController.stream;

  // ── Initialization ────────────────────────────────────────────────────────

  /// Call once from main() before runApp(). Registers plugin listeners here
  /// so they are registered exactly once for the lifetime of the process.
  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    await bg.BackgroundGeolocation.ready(
      bg.Config(
        desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
        distanceFilter: AppConstants.locationDistanceMeters,
        heartbeatInterval: AppConstants.locationIntervalSeconds,
        locationUpdateInterval: AppConstants.locationIntervalSeconds * 1000,
        fastestLocationUpdateInterval:
            AppConstants.locationIntervalSeconds * 1000,
        stopOnStationary: false,
        stopTimeout: 0,
        activityRecognitionInterval: 1000,
        minimumActivityRecognitionConfidence: 50,
        motionTriggerDelay: 0,
        elasticityMultiplier: 1,
        maxRecordsToPersist: 0,
        notification: bg.Notification(
          title: 'Tracking Active',
          text: 'Waiting for first location…',
          channelName: AppConstants.trackingChannelName,
          priority: bg.NotificationPriority.defaultPriority,
          smallIcon: 'mipmap/ic_launcher',
          sticky: true,
        ),
        foregroundService: true,
        enableHeadless: true,
        pausesLocationUpdatesAutomatically: false,
        showsBackgroundLocationIndicator: true,
        locationAuthorizationRequest: 'Always',
        stopOnTerminate: false,
        startOnBoot: true,
        debug: false,
        logLevel: bg.Config.LOG_LEVEL_WARNING,
      ),
    );

    // Register listeners once here; they survive start/stop cycles.
    bg.BackgroundGeolocation.onLocation(_onLocation, _onLocationError);
    bg.BackgroundGeolocation.onMotionChange(_onMotionChange);
    bg.BackgroundGeolocation.onActivityChange(_onActivityChange);
    bg.BackgroundGeolocation.onHeartbeat(_onHeartbeat);
    bg.BackgroundGeolocation.onProviderChange(_onProviderChange);

    _logger.i('[BGGeo] Plugin ready — '
        'distanceFilter=${AppConstants.locationDistanceMeters}m  '
        'interval=${AppConstants.locationIntervalSeconds}s');
  }

  // ── Plugin event handlers ─────────────────────────────────────────────────

  static DateTime? _lastEmittedTimestamp;
  static final _notifTimeFormat = DateFormat('hh:mm:ss a');

  static void _onLocation(bg.Location location) {
    final accuracy = location.coords.accuracy;

    if (accuracy > _accuracyThreshold) {
      _discardCount++;
      AppLogger.locationDiscarded(accuracy);
      _accuracyController.add({
        'accuracy': accuracy,
        'threshold': _accuracyThreshold,
        'timestamp': location.timestamp,
      });
      return;
    }

    final ts = location.timestamp;
    if (_lastEmittedTimestamp != null) {
      final parsed = DateTime.tryParse(ts);
      if (parsed != null &&
          parsed.difference(_lastEmittedTimestamp!).inMilliseconds.abs() <
              500) {
        _updateNotification(location);
        return;
      }
    }

    _emitCount++;
    _lastEmittedTimestamp = DateTime.tryParse(ts);
    final event = {
      'latitude': location.coords.latitude,
      'longitude': location.coords.longitude,
      'accuracy': accuracy,
      'heading': location.coords.heading,
      'speed': location.coords.speed,
      'timestamp': ts,
      'trigger': location.event ?? 'location',
      'sequenceNumber': _emitCount,
    };

    AppLogger.info(
      'BGGeo',
      'Location emitted #$_emitCount  '
          'lat=${location.coords.latitude.toStringAsFixed(6)}  '
          'lng=${location.coords.longitude.toStringAsFixed(6)}  '
          'acc=${accuracy.toStringAsFixed(1)}m  '
          'trigger=${location.event}',
    );

    _updateNotification(location);

    _locationController.add(event);
  }

  static void _updateNotification(bg.Location location) {
    try {
      final lat = location.coords.latitude;
      final lng = location.coords.longitude;
      final timeStr = _notifTimeFormat
          .format(DateTime.tryParse(location.timestamp) ?? DateTime.now());

      bg.BackgroundGeolocation.setConfig(
        bg.Config(
          notification: bg.Notification(
            title: 'Tracking Active',
            text:
                'Lat: ${lat.toStringAsFixed(5)}  Lng: ${lng.toStringAsFixed(5)}\n'
                'Updated: $timeStr',
            channelName: AppConstants.trackingChannelName,
            priority: bg.NotificationPriority.defaultPriority,
            smallIcon: 'mipmap/ic_launcher',
            sticky: true,
          ),
        ),
      );
    } catch (e) {
      // Non-fatal — notification failure must never crash the tracking pipeline.
      _logger.w('[BGGeo] Notification update failed: $e');
    }
  }

  static void _onLocationError(bg.LocationError error) {
    _logger.e('[BGGeo] Location error: ${error.code} — ${error.message}');
    _errorController.add({
      'error': '${error.code}: ${error.message}',
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  static void _onMotionChange(bg.Location location) {
    _logger.i('[BGGeo] Motion change: isMoving=${location.isMoving}  '
        'lat=${location.coords.latitude.toStringAsFixed(5)}');
  }

  static void _onActivityChange(bg.ActivityChangeEvent event) {
    _logger.i(
        '[BGGeo] Activity: ${event.activity}  confidence=${event.confidence}%');
  }

  static int _heartbeatCount = 0;
  static int _emitCount = 0;
  static int _discardCount = 0;
  static double _accuracyThreshold = AppConstants.minAccuracyMeters;

  static void _onHeartbeat(bg.HeartbeatEvent event) {
    _heartbeatCount++;

    _heartbeatController.add({
      'timestamp': DateTime.now().toIso8601String(),
      'heartbeatCount': _heartbeatCount,
      'emittedTotal': _emitCount,
      'discardedTotal': _discardCount,
    });

    bg.BackgroundGeolocation.getCurrentPosition(
      samples: 1,
      desiredAccuracy: AppConstants.minAccuracyMeters,
      timeout: (AppConstants.locationIntervalSeconds * 0.8).toInt(),
      maximumAge: (AppConstants.locationIntervalSeconds * 500).toInt(),
      persist: true,
    ).then((bg.Location loc) {
      AppLogger.info(
        'BGGeo',
        'Heartbeat-sourced fix #$_heartbeatCount  '
            'lat=${loc.coords.latitude.toStringAsFixed(6)}  '
            'lng=${loc.coords.longitude.toStringAsFixed(6)}  '
            'acc=${loc.coords.accuracy.toStringAsFixed(1)}m',
      );
    }).catchError((Object e) {
      // Timed out or location unavailable — not an error, just log it.
      AppLogger.debug('BGGeo', 'Heartbeat getCurrentPosition failed: $e');
    });
  }

  static void _onProviderChange(bg.ProviderChangeEvent event) {
    _logger.i('[BGGeo] Provider change: enabled=${event.enabled}  '
        'status=${event.status}  '
        'accuracyAuthorization=${event.accuracyAuthorization}');
    if (!event.enabled) {
      _errorController.add({
        'error': 'Location provider disabled (status=${event.status})',
        'timestamp': DateTime.now().toIso8601String(),
      });
    }
  }

  // ── Public API ────────────────────────────────────────────────────────────

  static Future<void> startService() async {
    AppLogger.backgroundServiceStarted();
    await bg.BackgroundGeolocation.start();
    _logger.i('[BGGeo] Tracking STARTED');
  }

  static Future<void> stopService() async {
    AppLogger.backgroundServiceStopped();
    await bg.BackgroundGeolocation.stop();

    // Reset notification to a neutral state after tracking stops.
    try {
      await bg.BackgroundGeolocation.setConfig(
        bg.Config(
          notification: bg.Notification(
            title: 'Tracking Stopped',
            text: 'Location tracking is not active.',
            channelName: AppConstants.trackingChannelName,
            priority: bg.NotificationPriority.min,
            smallIcon: 'mipmap/ic_launcher',
            sticky: false,
          ),
        ),
      );
    } catch (_) {}

    _logger.i('[BGGeo] Tracking STOPPED');
  }

  static Future<void> applyCountryConfig({
    required int intervalSeconds,
    required double distanceMeters,
    required double accuracyThreshold,
    String? tripId,
  }) async {
    _accuracyThreshold = accuracyThreshold;

    await bg.BackgroundGeolocation.setConfig(
      bg.Config(
        distanceFilter: distanceMeters,
        heartbeatInterval: intervalSeconds,
        locationUpdateInterval: intervalSeconds * 1000,
        fastestLocationUpdateInterval: intervalSeconds * 1000,
        desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
        // Re-apply motion/stationary settings so they survive setConfig calls.
        stopTimeout: 0,
        activityRecognitionInterval: 1000,
        minimumActivityRecognitionConfidence: 50,
      ),
    );

    AppLogger.info(
      'BGGeo_BRIDGE',
      'CountryConfig applied: '
          'interval=${intervalSeconds}s '
          'distance=${distanceMeters}m '
          'accuracy=${accuracyThreshold}m'
          '${tripId != null ? "  trip=$tripId" : ""}',
    );
  }

  static void resetCounters() {
    _heartbeatCount = 0;
    _emitCount = 0;
    _discardCount = 0;
    _lastEmittedTimestamp = null;
  }
}

// ── Headless task ─────────────────────────────────────────────────────────────
//
@pragma('vm:entry-point')
void headlessTask(bg.HeadlessEvent headlessEvent) async {
  // Only handle location events; ignore motionchange, heartbeat, etc.
  if (headlessEvent.name != bg.Event.LOCATION) return;

  final location = headlessEvent.event as bg.Location;
  final accuracy = location.coords.accuracy;

  // Apply the same accuracy guard used in the foreground path.
  if (accuracy > AppConstants.minAccuracyMeters) return;

  String? tripId;
  String? uuid;

  try {
    // Initialise Hive using the same app documents directory as the main isolate.
    // path_provider resolves to getFilesDir() on Android, which is consistent
    // across the main process and any background service process.
    final dir = await getApplicationDocumentsDirectory();
    await Hive.initFlutter(dir.path);

    // Register adapters if this is the first Hive call in this isolate.
    if (!Hive.isAdapterRegistered(LocationEntryAdapter.adapterTypeId)) {
      Hive.registerAdapter(LocationEntryAdapter());
    }
    if (!Hive.isAdapterRegistered(TelemetryEntryAdapter.adapterTypeId)) {
      Hive.registerAdapter(TelemetryEntryAdapter());
    }

    // Open the two boxes we need. Opening an already-open box is a no-op.
    const activeTripBoxName = 'active_trip';
    const locationQueueBoxName = 'location_queue';

    if (!Hive.isBoxOpen(activeTripBoxName)) {
      await Hive.openBox<Map>(activeTripBoxName);
    }
    if (!Hive.isBoxOpen(locationQueueBoxName)) {
      await Hive.openLazyBox<LocationEntry>(locationQueueBoxName);
    }

    // Read the active trip. Without a trip, there is nowhere to attach the entry.
    final activeTripBox = Hive.box<Map>(activeTripBoxName);
    final raw = activeTripBox.get('current');
    // Hive reads Box<Map> entries back as Map<dynamic,dynamic>. Use toString()
    // on the value to avoid a cast exception from Map<dynamic,dynamic>.
    tripId = raw != null ? (raw['trip_id'])?.toString() : null;
    if (tripId == null || tripId.isEmpty) return;

    // Build and persist the LocationEntry directly into the queue.
    uuid = const Uuid().v4();
    final ts = DateTime.tryParse(location.timestamp) ?? DateTime.now();

    final entry = LocationEntry(
      uuid: uuid,
      latitude: location.coords.latitude,
      longitude: location.coords.longitude,
      accuracy: accuracy,
      heading: location.coords.heading,
      speed: location.coords.speed,
      timestamp: ts,
      tripId: tripId,
    );

    final locationQueueBox = Hive.lazyBox<LocationEntry>(locationQueueBoxName);
    await locationQueueBox.put(uuid, entry);
    // FIX: flush() after every write in the headless isolate.
    // Without this, the write sits in Hive's in-memory buffer. If the
    // headless process is killed before the buffer is flushed automatically
    // (~4 KB threshold), the entry is silently lost.
    await locationQueueBox.flush();

    // Also update the latest-location pointer so restoration can seed the map.
    final latestKey = 'latest_loc:$tripId';
    await activeTripBox.put(latestKey, {'uuid': uuid});
    await activeTripBox.flush();

    AppLogger.info(
      'HEADLESS',
      'Location persisted to Hive  '
          'lat=${location.coords.latitude.toStringAsFixed(6)}  '
          'lng=${location.coords.longitude.toStringAsFixed(6)}  '
          'acc=${accuracy.toStringAsFixed(1)}m  '
          'trip=$tripId  '
          'uuid=${uuid.substring(0, 8)}',
    );

   try {
      final timeStr = DateFormat('hh:mm:ss a').format(ts);
      await bg.BackgroundGeolocation.setConfig(
        bg.Config(
          notification: bg.Notification(
            title: 'Tracking Active',
            text: 'Lat: ${location.coords.latitude.toStringAsFixed(5)}  '
                'Lng: ${location.coords.longitude.toStringAsFixed(5)}\n'
                'Updated: $timeStr',
            channelName: AppConstants.trackingChannelName,
            priority: bg.NotificationPriority.defaultPriority,
            smallIcon: 'mipmap/ic_launcher',
            sticky: true,
          ),
        ),
      );
    } catch (e) {
      AppLogger.error('HEADLESS', 'Notification update failed: $e', null);
    }
  } catch (e, st) {
    // Never rethrow in a headless task — an uncaught exception here crashes
    // the background service and prevents future headless callbacks.
    AppLogger.error(
        'HEADLESS', 'Failed to persist headless location to Hive: $e', st);
    // Cannot upload if we couldn't even save locally — bail out.
    return;
  }

  if (tripId == null || uuid == null) return;

  try {
    // Initialize Firebase in this isolate if not already done.
    // Firebase.apps.isEmpty is the correct check — initializeApp is idempotent
    // only if options match, so check first to avoid duplicate-app errors.
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      AppLogger.info('HEADLESS', 'Firebase initialized in headless isolate');
    }

    // Re-open boxes in case the try block above only partially succeeded.
    final locationQueueBox = Hive.lazyBox<LocationEntry>('location_queue');

    // Read all pending entries for this trip and upload them in one batch.
    // This drains the queue rather than uploading just the one new entry,
    // ensuring previously accumulated offline entries are also flushed.
    final allKeys = locationQueueBox.keys.toList();
    final batch = <LocationEntry>[];

    for (final key in allKeys) {
      if (batch.length >= 50) break; // Match AppConstants.batchUploadSize
      final entry = await locationQueueBox.get(key);
      if (entry != null && entry.tripId == tripId) {
        batch.add(entry);
      }
    }

    if (batch.isEmpty) return;

    final firestore = FirebaseFirestore.instance;
    final writeBatch = firestore.batch();
    final locationsRef =
        firestore.collection('trips').doc(tripId).collection('locations');
    final uploadedAt = FieldValue.serverTimestamp();

    for (final entry in batch) {
      final docRef = locationsRef.doc(entry.uuid);
      writeBatch.set(docRef, {
        'tripId': tripId,
        'latitude': entry.latitude,
        'longitude': entry.longitude,
        'accuracy': entry.accuracy,
        'timestamp': entry.timestamp.toIso8601String(),
        'uploadedAt': uploadedAt,
        'sequenceTimestamp': entry.timestamp.millisecondsSinceEpoch,
        'source': 'headless',
      });
    }

    await writeBatch.commit();

    // Remove successfully uploaded entries from Hive.
    final ackIds = batch.map((e) => e.uuid).toList();
    await locationQueueBox.deleteAll(ackIds);
    await locationQueueBox.flush();

    AppLogger.info(
      'HEADLESS',
      'Firebase batch upload succeeded  '
          'count=${ackIds.length}  trip=$tripId',
    );
  } catch (e, st) {
    // Firebase upload failed (offline, auth issue, etc.).
    // The Hive record written in Step 1 remains intact — it will be uploaded
    // by LocationRepositoryImpl when the app foregrounds or connectivity returns.
    AppLogger.error(
      'HEADLESS',
      'Firebase upload failed in headless (Hive record preserved for retry): $e',
      st,
    );
  }
}
