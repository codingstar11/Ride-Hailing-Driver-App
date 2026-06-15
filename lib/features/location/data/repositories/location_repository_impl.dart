import 'dart:async';
import 'dart:math';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'package:logger/logger.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/config/country_config.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/network/connectivity_service.dart';
import '../../../../core/services/background_service_handler.dart';
import '../../../../core/storage/driver_profile.dart';
import '../../../../core/storage/location_hive_datasource.dart';
import '../../../../core/utils/app_logger.dart';
import '../../domain/entities/driver_location.dart';
import '../../domain/repositories/location_repository.dart';
import '../datasources/location_remote_datasource.dart';

/// Repository coordinating Hive persistence, backend uploads (Firebase or
class LocationRepositoryImpl implements LocationRepository {
  final LocationHiveDatasource _localDatasource;
  final LocationRemoteDatasource _remoteDatasource;
  final ConnectivityService _connectivityService;
  final ConfigService _configService;
  final DriverProfileService _profileService;
  final _logger = Logger();
  final _uuid = const Uuid();

  bool _isTracking = false;
  String? _currentTripId;
  String _countryCode = 'PK';
  int _sequenceNumber = 0;

  CountryConfig _config = CountryConfig.pk;

  StreamSubscription? _bgLocationSub;
  StreamSubscription? _bgHeartbeatSub;
  StreamSubscription? _bgAccuracySub;
  StreamSubscription? _bgErrorSub;
  StreamSubscription? _connectivitySub;

  final _locationStreamController =
      StreamController<DriverLocation>.broadcast();

  // Upload lock — always reset in finally. Paired with a timeout guard so a
  // process-suspend mid-upload never permanently blocks future uploads.
  bool _isUploading = false;
  DateTime? _uploadStartedAt;
  static const Duration _uploadTimeout = Duration(seconds: 30);

  LocationRepositoryImpl({
    required LocationHiveDatasource localDatasource,
    required LocationRemoteDatasource remoteDatasource,
    required ConnectivityService connectivityService,
    required ConfigService configService,
    required DriverProfileService profileService,
  })  : _localDatasource = localDatasource,
        _remoteDatasource = remoteDatasource,
        _connectivityService = connectivityService,
        _configService = configService,
        _profileService = profileService {
    _listenToConnectivity();
  }

  void _listenToConnectivity() {
    _connectivitySub = _connectivityService.onConnectivityChanged.listen(
      (isConnected) async {
        if (isConnected) {
          AppLogger.networkRestored();
          _writeTelemetry('connectivity_restored', {});
          if (_currentTripId != null) {
            AppLogger.info(
                'REPO', 'Draining offline queue after connectivity restored');
            await uploadPendingLocations();
          }
        } else {
          AppLogger.networkDisconnected();
          _writeTelemetry('connectivity_lost', {});
        }
      },
    );
  }

  // ── LocationRepository interface ──────────────────────────────────────────

  @override
  bool get isTracking => _isTracking;

  @override
  void setCountryCode(String code) {
    _countryCode = code.toUpperCase();
    _logger.i('[Repo] Country code set to $_countryCode');
  }

  @override
  Stream<DriverLocation> get locationStream => _locationStreamController.stream;

  @override
  Future<String?> getActiveTripId() => _localDatasource.getActiveTripId();

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<void> startTracking(String tripId) async {
    if (_isTracking) {
      _logger.w(
          '[Repo] Already tracking — ignoring duplicate start  trip=$tripId');
      return;
    }

    _config = await _configService.getConfig(_countryCode);
    _currentTripId = tripId;
    _isTracking = true;
    _sequenceNumber = 0;

    AppLogger.tripStarted(tripId);
    _writeTelemetry(AppConstants.evtTripStarted, {'tripId': tripId});

    // saveActiveTrip now calls box.flush() internally.
    await _localDatasource.saveActiveTrip(tripId);
    await _remoteDatasource.reportTripStarted(tripId);
    await _recoverFromPreviousSession(tripId);

    BackgroundServiceHandler.resetCounters();

    // Subscribe BEFORE starting the plugin so no events are lost on a
    // broadcast stream that has zero listeners.
    _subscribeToBackgroundStreams(tripId);

    await BackgroundServiceHandler.applyCountryConfig(
      intervalSeconds: _config.locationIntervalSeconds.toInt(),
      distanceMeters: _config.locationDistanceMeters,
      accuracyThreshold: _config.minAccuracyMeters,
      tripId: tripId,
    );

    await BackgroundServiceHandler.startService();
  }

  @override
  Future<void> resumeTracking(String tripId) async {
    if (_isTracking) {
      _logger
          .w('[Repo] resumeTracking called but already tracking  trip=$tripId');
      return;
    }

    _config = await _configService.getConfig(_countryCode);
    _currentTripId = tripId;
    _isTracking = true;
    _sequenceNumber = await _localDatasource.getPendingCount(tripId: tripId);

    AppLogger.info(
        'REPO', 'Resuming active trip  trip=$tripId  seq=$_sequenceNumber');
    _writeTelemetry(
        'trip_resumed', {'tripId': tripId, 'resumedSeq': _sequenceNumber});

    // Ensure the active trip record is in Hive (it may have been recovered
    // from SharedPreferences and re-written asynchronously by getActiveTripId).
    // Call saveActiveTrip again to guarantee a fresh flush.
    await _localDatasource.saveActiveTrip(tripId);

    await _emitLatestSavedLocation(tripId);
    await _recoverFromPreviousSession(tripId);

    BackgroundServiceHandler.resetCounters();

    _subscribeToBackgroundStreams(tripId);

    await BackgroundServiceHandler.applyCountryConfig(
      intervalSeconds: _config.locationIntervalSeconds.toInt(),
      distanceMeters: _config.locationDistanceMeters,
      accuracyThreshold: _config.minAccuracyMeters,
      tripId: tripId,
    );

    await BackgroundServiceHandler.startService();
  }

  Future<void> _emitLatestSavedLocation(String tripId) async {
    try {
      final latest = await _localDatasource.getLatestLocation(tripId: tripId);
      if (latest == null) return;

      final location = DriverLocation(
        id: latest.uuid,
        latitude: latest.latitude,
        longitude: latest.longitude,
        accuracy: latest.accuracy,
        heading: latest.heading,
        speed: latest.speed,
        timestamp: latest.timestamp,
      );
      _locationStreamController.add(location);
      AppLogger.info(
          'REPO',
          'Restored last known location from Hive  '
              'lat=${location.latitude.toStringAsFixed(6)}  '
              'lng=${location.longitude.toStringAsFixed(6)}');
    } catch (e) {
      AppLogger.warn('REPO', 'Could not restore last location from Hive: $e');
    }
  }

  void _subscribeToBackgroundStreams(String tripId) {
    _bgLocationSub?.cancel();
    _bgHeartbeatSub?.cancel();
    _bgAccuracySub?.cancel();
    _bgErrorSub?.cancel();

    _bgLocationSub = BackgroundServiceHandler.locationStream.listen(
      _onLocationReceived,
      onError: (Object e) {
        AppLogger.error('REPO', 'Location stream error', e);
      },
    );

    _bgHeartbeatSub = BackgroundServiceHandler.heartbeatStream.listen(
      (data) {
        if (data != null) {
          final count = data['heartbeatCount'] as int? ?? 0;
          final ts = data['timestamp'] as String?;
          AppLogger.backgroundServiceHeartbeat(
            count,
            ts != null ? DateTime.parse(ts) : DateTime.now(),
          );
          _writeTelemetry('heartbeat', {
            'count': count,
            'emittedTotal': data['emittedTotal'],
          });
        }
      },
    );

    _bgAccuracySub = BackgroundServiceHandler.accuracyIssueStream.listen(
      (data) {
        if (data != null) {
          final acc = (data['accuracy'] as num?)?.toDouble() ?? 0;
          AppLogger.gpsAccuracyIssue(acc);
          _writeTelemetry('gps_accuracy_issue', {'accuracy': acc});
        }
      },
    );

    _bgErrorSub = BackgroundServiceHandler.errorStream.listen(
      (data) {
        if (data != null) {
          AppLogger.backgroundServiceError(data['error']);
          _writeTelemetry('service_error', data);
        }
      },
    );

    _logger.i('[Repo] Background streams subscribed  trip=$tripId');
  }

  @override
  Future<void> stopTracking() async {
    if (!_isTracking) return;

    _isTracking = false;
    final tripId = _currentTripId;

    if (tripId != null) {
      // Wait for any in-flight upload to complete (up to 3 s).
      int waitMs = 0;
      while (_isUploading && waitMs < 3000) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        waitMs += 100;
      }

      final pendingBeforeStop =
          await _localDatasource.getPendingCount(tripId: tripId);
      if (pendingBeforeStop > 0) {
        AppLogger.info('REPO',
            'Forcing final upload on trip stop  pending=$pendingBeforeStop');
        _writeTelemetry('stop_forced_upload', {
          'tripId': tripId,
          'pendingCount': pendingBeforeStop,
        });
        if (_connectivityService.isConnected) {
          await uploadPendingLocations();
        } else {
          AppLogger.warn('REPO',
              'Stop requested but offline — $pendingBeforeStop points remain pending');
          _writeTelemetry('stop_offline_pending', {
            'tripId': tripId,
            'pendingCount': pendingBeforeStop,
          });
        }
      }
    }

    await _bgLocationSub?.cancel();
    await _bgHeartbeatSub?.cancel();
    await _bgAccuracySub?.cancel();
    await _bgErrorSub?.cancel();
    _bgLocationSub = _bgHeartbeatSub = _bgAccuracySub = _bgErrorSub = null;

    await BackgroundServiceHandler.stopService();

    if (tripId != null) {
      final totalPoints =
          await _localDatasource.getPendingCount(tripId: tripId);
      await _localDatasource.archiveCompletedTrip({
        'trip_id': tripId,
        'ended_at': DateTime.now().toIso8601String(),
        'total_points_captured': _sequenceNumber,
        'pending_points_at_end': totalPoints,
      });

      bool ended = false;
      for (int attempt = 1; attempt <= 3 && !ended; attempt++) {
        try {
          await _remoteDatasource.reportTripEnded(
            tripId: tripId,
            totalPoints: _sequenceNumber,
          );
          ended = true;
        } catch (e) {
          AppLogger.warn('REPO', 'reportTripEnded attempt $attempt failed: $e');
          if (attempt < 3) {
            await Future<void>.delayed(Duration(seconds: attempt));
          }
        }
      }
      if (!ended) {
        AppLogger.error(
            'REPO',
            'reportTripEnded failed after 3 attempts — trip $tripId may remain active in Firestore',
            null);
      }

      final remaining = await _localDatasource.getPendingCount(tripId: tripId);
      if (remaining == 0) {
        await _localDatasource.clearActiveTrip();
      }

      _writeTelemetry(AppConstants.evtTripEnded, {
        'tripId': tripId,
        'totalPoints': _sequenceNumber,
        'pendingAtEnd': totalPoints,
      });
    }

    await _localDatasource.cleanupStaleEntries();

    _currentTripId = null;
    AppLogger.tripStopped(tripId ?? 'unknown', totalPoints: _sequenceNumber);
  }

  @override
  Future<void> saveLocationLocally(DriverLocation location) {
    if (_currentTripId == null) return Future.value();
    return _localDatasource.saveLocation(location, _currentTripId!);
  }

  @override
  Future<int> uploadPendingLocations() async {
    // Stuck-lock guard: if the flag has been held longer than _uploadTimeout
    // (e.g. process was suspended mid-upload), force-release it.
    if (_isUploading) {
      final started = _uploadStartedAt;
      if (started != null &&
          DateTime.now().difference(started) > _uploadTimeout) {
        _logger.w(
            '[Repo] Upload lock held for >${_uploadTimeout.inSeconds}s — force-releasing');
        _isUploading = false;
        _uploadStartedAt = null;
      } else {
        _logger
            .d('[Repo] Upload already in progress — skipping concurrent call');
        return 0;
      }
    }

    final tripId = _currentTripId ?? await _localDatasource.getActiveTripId();
    if (tripId == null) return 0;

    final pending = await _localDatasource.getPendingLocations(
      tripId: tripId,
      limit: AppConstants.batchUploadSize,
    );
    if (pending.isEmpty) {
      _logger.d('[Repo] Upload requested but queue is empty');
      return 0;
    }

    String? driverId;
    try {
      final profile = await _profileService.getProfile();
      driverId = profile.id.isEmpty ? null : profile.id;
    } catch (_) {}

    AppLogger.uploadStarted(pending.length, tripId);
    _writeTelemetry('upload_attempt', {
      'count': pending.length,
      'tripId': tripId,
    });

    _isUploading = true;
    _uploadStartedAt = DateTime.now();

    try {
      final ackIds = await _remoteDatasource.uploadLocationBatch(
        locations: pending,
        tripId: tripId,
        driverId: driverId,
      );

      if (ackIds.isNotEmpty) {
        await _localDatasource.deleteConfirmed(ackIds);
        AppLogger.uploadSuccess(ackIds.length);
        _writeTelemetry(AppConstants.evtLocationUploaded, {
          'count': ackIds.length,
          'tripId': tripId,
        });

        if (!_isTracking) {
          final remaining =
              await _localDatasource.getPendingCount(tripId: tripId);
          if (remaining == 0) {
            await _localDatasource.clearActiveTrip();
            _logger.i(
                '[Repo] All pending uploaded post-stop — active trip marker cleared');
          }
        }

        return ackIds.length;
      }
    } catch (e) {
      for (final entry in pending) {
        await _localDatasource.incrementRetry(entry.uuid);
      }
      AppLogger.uploadFailed(e);
      _writeTelemetry(AppConstants.evtUploadFailed, {
        'error': e.toString(),
        'tripId': tripId,
        'pendingCount': pending.length,
      });
    } finally {
      // Always release the lock — even if an exception is thrown anywhere
      // between _isUploading = true and this finally block.
      _isUploading = false;
      _uploadStartedAt = null;
    }

    return 0;
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  Future<void> _onLocationReceived(Map<String, dynamic>? event) async {
    if (event == null) return;
    await handleBackgroundLocationEvent(event);
  }

  @override
  Future<void> handleBackgroundLocationEvent(Map<String, dynamic> event) async {
    final activeTripId =
        _currentTripId ?? await _localDatasource.getActiveTripId();
    if (activeTripId == null) return;

    // Self-heal: restore in-memory state if the repo was restarted but Hive
    // (or SharedPreferences) still has the active trip.
    if (_currentTripId == null) {
      _currentTripId = activeTripId;
      _isTracking = true;
      AppLogger.info(
          'REPO', 'Recovered _currentTripId from storage  trip=$activeTripId');
    }

    try {
      final accuracy = (event['accuracy'] as num).toDouble();
      final lat = (event['latitude'] as num).toDouble();
      final lng = (event['longitude'] as num).toDouble();
      final tsRaw = event['timestamp'];
      final timestamp = tsRaw is String
          ? DateTime.tryParse(tsRaw) ?? DateTime.now()
          : DateTime.now();

      AppLogger.locationReceived(
        lat: lat,
        lng: lng,
        accuracy: accuracy,
        speed:
            event['speed'] != null ? (event['speed'] as num).toDouble() : null,
      );

     if (accuracy > _config.minAccuracyMeters) {
        AppLogger.locationDiscarded(accuracy);
        return;
      }

      final id = event['uuid'] as String? ?? _uuid.v4();

      final location = DriverLocation(
        id: id,
        latitude: lat,
        longitude: lng,
        accuracy: accuracy,
        heading: event['heading'] != null
            ? (event['heading'] as num).toDouble()
            : null,
        speed:
            event['speed'] != null ? (event['speed'] as num).toDouble() : null,
        timestamp: timestamp,
      );

      // Write to Hive + flush() before attempting any upload.
      // If the upload fails or the process is killed mid-upload, the entry
      // is already on disk and will be retried on the next launch.
      await _localDatasource.saveLocation(location, activeTripId);
      _sequenceNumber++;

      // Emit to UI stream (MapBloc consumes this).
      _locationStreamController.add(location);

      // Trigger upload non-blocking. Using unawaited + catchError so the
      // location processing pipeline is never blocked waiting for Firestore.
      // The _isUploading guard inside uploadPendingLocations() serialises
      // concurrent calls; the timeout guard prevents a stuck flag.
      if (_connectivityService.isConnected) {
        uploadPendingLocations().catchError((Object e) {
          AppLogger.error('REPO', 'Background upload error (non-fatal)', e);
          return 0;
        });
      }

      _writeTelemetry('location_received', {
        'lat': lat,
        'lng': lng,
        'accuracy': accuracy,
      });
    } catch (e) {
      AppLogger.error('REPO', 'Error processing location event', e);
    }
  }

  double _calculateDistance(
      double lat1, double lng1, double lat2, double lng2) {
    const earthRadius = 6371000.0;
    final dLat = _toRad(lat2 - lat1);
    final dLng = _toRad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRad(lat1)) * cos(_toRad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  double _toRad(double deg) => deg * pi / 180.0;

  Future<void> _recoverFromPreviousSession(String tripId) async {
    final recovered =
        await _localDatasource.recoverPendingFromPreviousSession();
    final matching = recovered.where((e) => e.tripId == tripId).toList();

    if (matching.isEmpty) {
      _logger.i('[Repo] No entries to recover for trip $tripId');
      return;
    }

    AppLogger.info('REPO',
        'Recovering ${matching.length} entries from previous session  trip=$tripId');
    _writeTelemetry('session_recovery', {
      'count': matching.length,
      'tripId': tripId,
    });

    if (_connectivityService.isConnected) {
      try {
        await uploadPendingLocations();
      } catch (e) {
        AppLogger.warn(
            'REPO', 'Session recovery upload failed (will retry): $e');
      }
    }
  }

  void _writeTelemetry(String event, Map<String, dynamic> data) {
    AppLogger.telemetryPersisted(event);
    _localDatasource.writeTelemetryEvent(
      event: event,
      tripId: _currentTripId ?? 'none',
      extra: data,
    );
  }

  // ── Stream interface ──────────────────────────────────────────────────────

  @override
  Stream<int> get pendingLocationCount => _localDatasource.pendingCountStream;

  @override
  Future<int> getPendingCount() =>
      _localDatasource.getPendingCount(tripId: _currentTripId);

  @override
  Stream<DriverLocation> get foregroundLocationStream {
    final controller = StreamController<DriverLocation>.broadcast();
    StreamSubscription? innerSub;

    controller.onListen = () async {
      try {
        final pos = await bg.BackgroundGeolocation.getCurrentPosition(
          samples: 1,
          desiredAccuracy: 40,
          timeout: 10,
          maximumAge: 10000,
        );
        if (!controller.isClosed) {
          controller.add(DriverLocation(
            id: _uuid.v4(),
            latitude: pos.coords.latitude,
            longitude: pos.coords.longitude,
            accuracy: pos.coords.accuracy,
            heading: pos.coords.heading,
            speed: pos.coords.speed,
            timestamp: DateTime.tryParse(pos.timestamp) ?? DateTime.now(),
          ));
        }
      } catch (e) {
        AppLogger.warn('REPO', 'Foreground seed fix failed: $e');
      }

      if (!controller.isClosed) {
        innerSub = _locationStreamController.stream.listen(
          (loc) {
            // FIX: The original condition `!_isTracking` caused foreground UI
            // (MapBloc) to receive ZERO location updates while tracking was
            // active. The intent was to stop emitting after trip ends, but
            // the condition was inverted. The stream should forward all events
            // while the controller is open; the caller cancels the subscription
            // when it no longer needs updates.
            if (!controller.isClosed) {
              controller.add(loc);
            }
          },
          onError: (Object e) {
            AppLogger.warn('REPO', 'Foreground stream error: $e');
          },
          onDone: () {
            if (!controller.isClosed) controller.close();
          },
        );
      }
    };

    controller.onCancel = () {
      innerSub?.cancel();
      innerSub = null;
    };

    return controller.stream;
  }

  void dispose() {
    _bgLocationSub?.cancel();
    _bgHeartbeatSub?.cancel();
    _bgAccuracySub?.cancel();
    _bgErrorSub?.cancel();
    _connectivitySub?.cancel();
    _locationStreamController.close();
    _localDatasource.dispose();
  }
}