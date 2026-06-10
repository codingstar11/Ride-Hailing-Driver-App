import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../constants/app_constants.dart';
import '../storage/location_entry.dart';
import '../storage/telemetry_entry.dart';
import '../utils/app_logger.dart';

/// @pragma('vm:entry-point') on the CLASS is required so the AOT compiler
/// does not tree-shake it when the plugin accesses it reflectively.
@pragma('vm:entry-point')
class BackgroundServiceHandler {

  // ── Firebase options for the background isolate ──
  // Duplicated from firebase_options.dart to avoid importing
  // flutter/foundation (which needs WidgetsBinding) in this isolate.
  static const _androidFirebaseOptions = FirebaseOptions(
    apiKey: 'AIzaSyATT-T6Bz_LtqN-mYe-QZD5Dk90Mg6bm04',
    appId: '1:465819976739:android:6d722ca9defcb95f16dd96',
    messagingSenderId: '465819976739',
    projectId: 'ride-hailing-app-375aa',
    storageBucket: 'ride-hailing-app-375aa.firebasestorage.app',
  );

  static const _iosFirebaseOptions = FirebaseOptions(
    apiKey: 'AIzaSyDgVfZyy87qFSVmlF69QD8tV6EgqQFyBDk',
    appId: '1:465819976739:ios:6101db1a2bc762ee16dd96',
    messagingSenderId: '465819976739',
    projectId: 'ride-hailing-app-375aa',
    storageBucket: 'ride-hailing-app-375aa.firebasestorage.app',
    iosBundleId: 'com.ridehailing.driver',
  );

  static Future<void> initialize() async {
    final service = FlutterBackgroundService();

    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      AppConstants.trackingChannelId,
      AppConstants.trackingChannelName,
      description: 'Background location tracking for active trips',
      importance: Importance.low,
    );

    final FlutterLocalNotificationsPlugin notifications =
        FlutterLocalNotificationsPlugin();

    await notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: AppConstants.trackingChannelId,
        initialNotificationTitle: 'Driver Tracking Active',
        initialNotificationContent: 'Your location is being tracked',
        foregroundServiceNotificationId: AppConstants.trackingNotificationId,
        foregroundServiceTypes: [AndroidForegroundType.location],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );
  }

  /// iOS background handler — invoked by the system on significant-location-
  /// change events after the normal ~170 s foreground budget expires.
  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();

    if (!Platform.isIOS) return true;

    final logger = Logger();
    logger.i('[BG_SVC_IOS] Significant-location-change wake  '
        't=${DateTime.now().toIso8601String()}');

    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 20),
      );

      final now = DateTime.now();
      logger.i('[BG_SVC_IOS] SLC fix acquired  '
          'lat=${position.latitude.toStringAsFixed(6)}  '
          'lng=${position.longitude.toStringAsFixed(6)}  '
          'acc=${position.accuracy.toStringAsFixed(1)}m');

      service.invoke('locationUpdate', {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        'heading': position.heading,
        'speed': position.speed,
        'timestamp': now.toIso8601String(),
        'trigger': 'ios_significant_location_change',
        'sequenceNumber': -1,
      });
    } catch (e) {
      logger.w('[BG_SVC_IOS] Could not get position on SLC wake: $e');
    }

    return true;
  }

  // ── Background isolate entry point ────────────────────────────────────────

  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {
    DartPluginRegistrant.ensureInitialized();

    final logger = Logger();
    const uuid = Uuid();

    logger.i(
        '🟢 [BG_SVC] ══ Background service STARTED ══  time=${DateTime.now().toIso8601String()}');
    service.invoke(
        'serviceStarted', {'timestamp': DateTime.now().toIso8601String()});

    // ── Step 1: Initialize Firebase inside this isolate ───────────
    // Required so Firestore writes work when the main isolate is dead.
    // Firebase.apps.isNotEmpty means already initialized (service restart).
    FirebaseFirestore? firestore;
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: Platform.isIOS ? _iosFirebaseOptions : _androidFirebaseOptions,
        );
        logger.i('[BG_SVC] Firebase initialized in background isolate');
      } else {
        logger.i('[BG_SVC] Firebase already initialized — reusing existing app');
      }
      firestore = FirebaseFirestore.instance;
    } catch (e) {
      logger.e('[BG_SVC] Firebase init failed: $e — uploads will be skipped');
    }

    // ── Step 2: Initialize Hive inside this isolate ───────────────────────
    // Both isolates open the same on-disk files; Hive handles concurrency.
    bool hiveReady = false;
    try {
      final dir = await getApplicationDocumentsDirectory();
      await Hive.initFlutter(dir.path);

      if (!Hive.isAdapterRegistered(LocationEntryAdapter.adapterTypeId)) {
        Hive.registerAdapter(LocationEntryAdapter());
      }
      if (!Hive.isAdapterRegistered(TelemetryEntryAdapter.adapterTypeId)) {
        Hive.registerAdapter(TelemetryEntryAdapter());
      }

      if (!Hive.isBoxOpen('location_queue')) {
        await Hive.openLazyBox<LocationEntry>('location_queue');
      }
      if (!Hive.isBoxOpen('active_trip')) {
        await Hive.openBox<Map>('active_trip');
      }

      hiveReady = true;
      logger.i('[BG_SVC] Hive initialized in background isolate');
    } catch (e) {
      logger.e('[BG_SVC] Hive init failed: $e — persistence will be skipped');
    }

    // ── Step 3: Read the active tripId ────────────────────────────────────
    // Written by the main isolate in LocationHiveDatasource.saveActiveTrip().
    String? activeTripId;
    if (hiveReady) {
      try {
        final data = Hive.box<Map>('active_trip').get('current');
        activeTripId = data?['trip_id'] as String?;
        logger.i('[BG_SVC] Active trip from Hive: $activeTripId');
      } catch (e) {
        logger.w('[BG_SVC] Could not read active trip from Hive: $e');
      }
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    /// Saves a location directly to the Hive location_queue box.
    Future<String?> saveToHive(Map<String, dynamic> event, String tripId) async {
      if (!hiveReady) return null;
      try {
        final id = uuid.v4();
        final entry = LocationEntry(
          uuid: id,
          latitude: (event['latitude'] as num).toDouble(),
          longitude: (event['longitude'] as num).toDouble(),
          accuracy: (event['accuracy'] as num).toDouble(),
          heading: event['heading'] != null
              ? (event['heading'] as num).toDouble()
              : null,
          speed: event['speed'] != null
              ? (event['speed'] as num).toDouble()
              : null,
          timestamp: DateTime.parse(event['timestamp'] as String),
          tripId: tripId,
        );
        await Hive.lazyBox<LocationEntry>('location_queue').put(id, entry);
        logger.d('[BG_SVC] Saved to Hive  uuid=$id  trip=$tripId');
        return id;
      } catch (e) {
        logger.e('[BG_SVC] Hive save failed: $e');
        return null;
      }
    }

    /// Uploads all pending entries for [tripId] from Hive to Firestore and
    /// deletes confirmed entries. Returns the number uploaded.
    Future<int> uploadPending(String tripId) async {
      if (firestore == null || !hiveReady) return 0;

      try {
        final box = Hive.lazyBox<LocationEntry>('location_queue');
        final allKeys = box.keys.toList();
        final pending = <LocationEntry>[];

        for (final key in allKeys) {
          if (pending.length >= AppConstants.batchUploadSize) break;
          final entry = await box.get(key);
          if (entry != null && entry.tripId == tripId) {
            pending.add(entry);
          }
        }

        if (pending.isEmpty) return 0;

        final batch = firestore!.batch();
        final locationsRef = firestore!
            .collection('trips')
            .doc(tripId)
            .collection('locations');

        for (final entry in pending) {
          batch.set(locationsRef.doc(entry.uuid), {
            'tripId': tripId,
            'latitude': entry.latitude,
            'longitude': entry.longitude,
            'accuracy': entry.accuracy,
            'timestamp': entry.timestamp.toIso8601String(),
            'uploadedAt': FieldValue.serverTimestamp(),
            if (entry.heading != null) 'heading': entry.heading,
            if (entry.speed != null) 'speed': entry.speed,
            'sequenceTimestamp': entry.timestamp.millisecondsSinceEpoch,
          });
        }

        await batch.commit();

        final ackIds = pending.map((e) => e.uuid).toList();
        await box.deleteAll(ackIds);

        logger.i('[BG_SVC] Uploaded & confirmed ${ackIds.length} locations  trip=$tripId');
        return ackIds.length;
      } catch (e) {
        logger.e('[BG_SVC] Upload failed: $e — will retry');
        return 0;
      }
    }

    // ── GPS stream state ──────────────────────────────────────────────────
    Position? lastPosition;
    DateTime? lastUpdateTime;
    int heartbeatCount = 0;
    int locationEmitCount = 0;
    int discardedCount = 0;

    int intervalSeconds = AppConstants.locationIntervalSeconds;
    double distanceMeters = AppConstants.locationDistanceMeters;
    double accuracyThreshold = AppConstants.minAccuracyMeters;

    if (service is AndroidServiceInstance) {
      service.on('setAsForeground').listen((_) {
        logger.i('🌕 [BG_SVC] Promoted to FOREGROUND service');
        service.setAsForegroundService();
      });
      service.on('setAsBackground').listen((_) {
        logger.i('🌑 [BG_SVC] Demoted to BACKGROUND service');
        service.setAsBackgroundService();
      });
    }

    // ── Periodic drain timer ──────────────────────────────────────────────
    // Retries any locations that failed to upload on the immediate attempt.
    // Runs every 30s independently of GPS events.
    Timer? drainTimer;

    void startDrainTimer() {
      drainTimer?.cancel();
      drainTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
        final tid = activeTripId;
        if (tid == null) {
          // tripId may arrive after startLocationStream — re-read from Hive.
          try {
            final data = Hive.box<Map>('active_trip').get('current');
            activeTripId = data?['trip_id'] as String?;
          } catch (_) {}
          return;
        }
        final uploaded = await uploadPending(tid);
        if (uploaded > 0) {
          logger.i('[BG_SVC] Drain timer flushed $uploaded locations  trip=$tid');
        }
      });
    }

    // ── GPS stream ────────────────────────────────────────────────────────
    StreamSubscription<Position>? positionSub;

    void startLocationStream() {
      positionSub?.cancel();
      positionSub = null;

      logger.i('[BG_SVC] Starting position stream  '
          'interval=${intervalSeconds}s  '
          'distance=${distanceMeters}m  '
          'accuracy=${accuracyThreshold}m');

      try {
        final locationSettings = Platform.isAndroid
            ? AndroidSettings(
                accuracy: LocationAccuracy.high,
                distanceFilter: 0,
                intervalDuration: Duration(seconds: intervalSeconds),
                foregroundNotificationConfig: const ForegroundNotificationConfig(
                  notificationText: 'Tracking your location',
                  notificationTitle: 'Driver Tracking Active',
                  enableWakeLock: true,
                ),
              )
            : LocationSettings(
                accuracy: LocationAccuracy.high,
                distanceFilter: 0,
              );

        positionSub = Geolocator.getPositionStream(
          locationSettings: locationSettings,
        ).listen(
          (position) async {
            final now = DateTime.now();
            heartbeatCount++;

            if (heartbeatCount % 6 == 0) {
              logger.d('💓 [BG_SVC] Heartbeat #$heartbeatCount  '
                  'emitted=$locationEmitCount  discarded=$discardedCount  '
                  'acc=${position.accuracy.toStringAsFixed(1)}m');
              service.invoke('heartbeat', {
                'timestamp': now.toIso8601String(),
                'heartbeatCount': heartbeatCount,
                'emittedTotal': locationEmitCount,
                'discardedTotal': discardedCount,
                'accuracy': position.accuracy,
              });
            }

            // ── Accuracy gate ─────────────────────────────────────────────
            if (position.accuracy > accuracyThreshold) {
              discardedCount++;
              logger.w('📡 [BG_SVC] Low accuracy — skipping  '
                  'acc=${position.accuracy.toStringAsFixed(1)}m  '
                  'threshold=${accuracyThreshold}m');
              service.invoke('accuracyIssue', {
                'accuracy': position.accuracy,
                'threshold': accuracyThreshold,
                'timestamp': now.toIso8601String(),
              });
              return;
            }

            // ── Time gate ─────────────────────────────────────────────────
            final timeSinceLast = lastUpdateTime == null
                ? Duration(seconds: intervalSeconds + 1)
                : now.difference(lastUpdateTime!);
            final timeThresholdMet =
                timeSinceLast.inSeconds >= intervalSeconds;

            // ── Distance gate ─────────────────────────────────────────────
            bool distanceThresholdMet = false;
            double? distanceTravelled;
            if (lastPosition != null) {
              distanceTravelled = Geolocator.distanceBetween(
                lastPosition!.latitude,
                lastPosition!.longitude,
                position.latitude,
                position.longitude,
              );
              distanceThresholdMet = distanceTravelled >= distanceMeters;
            } else {
              distanceThresholdMet = true;
            }

            if (!timeThresholdMet && !distanceThresholdMet) return;

            lastPosition = position;
            lastUpdateTime = now;
            locationEmitCount++;

            final trigger = timeThresholdMet
                ? 'time(${timeSinceLast.inSeconds}s)'
                : 'dist(${distanceTravelled?.toStringAsFixed(1)}m)';

            logger.i('📍 [BG_SVC] Location emitted #$locationEmitCount  '
                'lat=${position.latitude.toStringAsFixed(6)}  '
                'lng=${position.longitude.toStringAsFixed(6)}  '
                'acc=${position.accuracy.toStringAsFixed(1)}m  '
                'trigger=$trigger  '
                'speed=${position.speed.toStringAsFixed(1)}m/s');

            // ── Notify main isolate (UI map update) ───────────────────────
            // Not in critical path — if main isolate is dead this is a no-op.
            service.invoke('locationUpdate', {
              'latitude': position.latitude,
              'longitude': position.longitude,
              'accuracy': position.accuracy,
              'heading': position.heading,
              'speed': position.speed,
              'timestamp': now.toIso8601String(),
              'trigger': trigger,
              'sequenceNumber': locationEmitCount,
            });

            // ── Update foreground notification ────────────────────────────
            if (service is AndroidServiceInstance) {
              service.setForegroundNotificationInfo(
                title: 'Trip in Progress',
                content:
                    '📍 ${position.latitude.toStringAsFixed(5)}, '
                    '${position.longitude.toStringAsFixed(5)}  '
                    '| acc: ${position.accuracy.toStringAsFixed(0)}m  '
                    '| ${now.hour}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}  '
                    '| #$locationEmitCount fixes',
              );
            }

            // ── Persist to Hive + upload to Firestore ─────────────────────
            // This runs in the background isolate so it survives app kill.
            final tid = activeTripId;
            if (tid == null) {
              // Trip may not have started yet or Hive read failed at init.
              // Try reading again — the main isolate writes it on trip start.
              try {
                if (hiveReady) {
                  final data = Hive.box<Map>('active_trip').get('current');
                  activeTripId = data?['trip_id'] as String?;
                }
              } catch (_) {}
              if (activeTripId == null) {
                logger.w('[BG_SVC] No active tripId — location not persisted');
                return;
              }
            }

            final savedId = await saveToHive(
              {
                'latitude': position.latitude,
                'longitude': position.longitude,
                'accuracy': position.accuracy,
                'heading': position.heading,
                'speed': position.speed,
                'timestamp': now.toIso8601String(),
              },
              activeTripId!,
            );

            if (savedId != null) {
              await uploadPending(activeTripId!);
            }
          },
          onError: (Object e, StackTrace stack) {
            logger.e('❌ [BG_SVC] Position stream error  $e\n$stack');
            service.invoke('serviceError', {
              'error': e.toString(),
              'timestamp': DateTime.now().toIso8601String(),
            });
          },
          cancelOnError: false,
        );
      } catch (e, stack) {
        logger.e('❌ [BG_SVC] Could not start position stream  $e\n$stack');
        service.invoke('serviceError', {
          'error': e.toString(),
          'timestamp': DateTime.now().toIso8601String(),
        });
      }
    }

    // ── Config update handler ─────────────────────────────────────────────
    service.on('applyConfig').listen((data) {
      if (data == null) return;
      intervalSeconds = (data['intervalSeconds'] as num?)?.toInt() ??
          AppConstants.locationIntervalSeconds;
      distanceMeters = (data['distanceMeters'] as num?)?.toDouble() ??
          AppConstants.locationDistanceMeters;
      accuracyThreshold = (data['accuracyThreshold'] as num?)?.toDouble() ??
          AppConstants.minAccuracyMeters;
      // Prefer explicitly passed tripId; fall back to Hive read.
      final passedTripId = data['tripId'] as String?;
      if (passedTripId != null) {
        activeTripId = passedTripId;
        logger.i('[BG_SVC] Trip ID set from applyConfig: $activeTripId');
      } else if (hiveReady) {
        try {
          final data2 = Hive.box<Map>('active_trip').get('current');
          activeTripId = data2?['trip_id'] as String?;
        } catch (_) {}
      }
      logger.i('[BG_SVC] Config applied: '
          'interval=${intervalSeconds}s '
          'distance=${distanceMeters}m '
          'accuracy=${accuracyThreshold}m  '
          'trip=$activeTripId');
      startLocationStream();
    });

    // ── Stop handler ──────────────────────────────────────────────────────
    service.on('stopService').listen((_) async {
      logger.i('🔴 [BG_SVC] ══ Stop signal received ══  '
          'emitted=$locationEmitCount  discarded=$discardedCount');
      positionSub?.cancel();
      positionSub = null;
      drainTimer?.cancel();
      drainTimer = null;
      service.stopSelf();
    });

    // ── Start GPS stream and drain timer ──────────────────────────────────
    startLocationStream();
    startDrainTimer();
  }

  // ── Public API called from the main isolate ──────────────────────────────

  static Future<void> startService() async {
    AppLogger.backgroundServiceStarted();
    await FlutterBackgroundService().startService();
  }

  static Future<void> stopService() async {
    AppLogger.backgroundServiceStopped();
    FlutterBackgroundService().invoke('stopService');

    try {
      final FlutterLocalNotificationsPlugin notifications =
          FlutterLocalNotificationsPlugin();
      await notifications.cancel(AppConstants.trackingNotificationId);
    } catch (e) {
      AppLogger.warn('BG_SVC', 'Could not cancel notification: $e');
    }
  }

  static void applyCountryConfig({
    required int intervalSeconds,
    required double distanceMeters,
    required double accuracyThreshold,
    String? tripId,
  }) {
    FlutterBackgroundService().invoke('applyConfig', {
      'intervalSeconds': intervalSeconds,
      'distanceMeters': distanceMeters,
      'accuracyThreshold': accuracyThreshold,
      if (tripId != null) 'tripId': tripId,
    });
    AppLogger.info(
        'BG_SVC_BRIDGE',
        'CountryConfig applied to background service: '
            'interval=${intervalSeconds}s '
            'distance=${distanceMeters}m '
            'accuracy=${accuracyThreshold}m');
  }

  static Stream<Map<String, dynamic>?> get locationStream =>
      FlutterBackgroundService().on('locationUpdate');

  static Stream<Map<String, dynamic>?> get heartbeatStream =>
      FlutterBackgroundService().on('heartbeat');

  static Stream<Map<String, dynamic>?> get accuracyIssueStream =>
      FlutterBackgroundService().on('accuracyIssue');

  static Stream<Map<String, dynamic>?> get errorStream =>
      FlutterBackgroundService().on('serviceError');
}