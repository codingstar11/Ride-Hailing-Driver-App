import 'dart:async';
import 'package:geolocator/geolocator.dart';
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
/// Mock), background service events, and connectivity-driven sync.
///
/// Data flow (happy path)
/// ──────────────────────
///   BackgroundService → locationUpdate event
///       ↓
///   _onLocationReceived() — accuracy gate (≤ minAccuracyMeters from config)
///       ↓
///   LocationHiveDatasource.saveLocation()     ← written to Hive first
///       ↓  (if online & batch threshold met)
///   _tryUpload() → LocationRemoteDatasource.uploadLocationBatch()
///       ↓  (on ACK)
///   LocationHiveDatasource.deleteConfirmed()
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

  // ── LocationRepository interface ─────────────────────────────────────────

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

    await _localDatasource.saveActiveTrip(tripId);
    await _remoteDatasource.reportTripStarted(tripId);
    await _recoverFromPreviousSession(tripId);

    // Allow any previously-stopping service instance to fully shut down
    // before starting a new one. The stopService invoke is fire-and-forget
    // so without this delay the new onStart may race with the old stopSelf.
    await Future.delayed(const Duration(milliseconds: 500));

    await BackgroundServiceHandler.startService();

    BackgroundServiceHandler.applyCountryConfig(
      intervalSeconds: _config.locationIntervalSeconds.toInt(),
      distanceMeters: _config.locationDistanceMeters,
      accuracyThreshold: _config.minAccuracyMeters,
      tripId: tripId,
    );

    _subscribeToBackgroundStreams(tripId);
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

    await _emitLatestSavedLocation(tripId);
    await _recoverFromPreviousSession(tripId);
    await BackgroundServiceHandler.startService();

    BackgroundServiceHandler.applyCountryConfig(
      intervalSeconds: _config.locationIntervalSeconds.toInt(),
      distanceMeters: _config.locationDistanceMeters,
      accuracyThreshold: _config.minAccuracyMeters,
    );

    _subscribeToBackgroundStreams(tripId);
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
            'accuracy': data['accuracy'],
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

    _logger.i('[Repo] All background streams subscribed for trip=$tripId');
  }

  @override
  Future<void> stopTracking() async {
    if (!_isTracking) return;

    _isTracking = false;
    final tripId = _currentTripId;

    if (tripId != null) {
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

      await _remoteDatasource.reportTripEnded(
        tripId: tripId,
        totalPoints: _sequenceNumber,
      );

      await _localDatasource.clearActiveTrip();
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
    // Prefer in-memory tripId; fall back to Hive for the boot-recovery path
    // where the background service is running but resumeTracking() has not
    // yet been called (process killed, service restarted by BootReceiver).
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

    // Resolve driverId once per upload batch — non-blocking, defaults to null.
    String? driverId;
    try {
      final profile = await _profileService.getProfile();
      driverId = profile.id.isEmpty ? null : profile.id;
    } catch (_) {
      // driverId stays null — upload proceeds without it.
    }

    AppLogger.uploadStarted(pending.length, tripId);
    _writeTelemetry('upload_attempt', {
      'count': pending.length,
      'tripId': tripId,
    });

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
    }

    return 0;
  }

  // ── Internal ─────────────────────────────────────────────────────────────

  Future<void> _onLocationReceived(Map<String, dynamic>? event) async {
    if (event == null) return;

    final activeTripId =
        _currentTripId ?? await _localDatasource.getActiveTripId();
    if (activeTripId == null) return;

    if (_currentTripId == null) {
      _currentTripId = activeTripId;
      _isTracking = true;
      AppLogger.info('REPO',
          'Recovered _currentTripId from Hive in _onLocationReceived  trip=$activeTripId');
    }

    try {
      final accuracy = (event['accuracy'] as num).toDouble();
      final lat = (event['latitude'] as num).toDouble();
      final lng = (event['longitude'] as num).toDouble();

      AppLogger.locationReceived(
        lat: lat,
        lng: lng,
        accuracy: accuracy,
        speed: event['speed'] != null ? (event['speed'] as num).toDouble() : null,
      );

      // Accuracy gate — only for UI stream filtering; background isolate
      // already applied this gate before persisting.
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
        speed: event['speed'] != null
            ? (event['speed'] as num).toDouble()
            : null,
        timestamp: DateTime.parse(event['timestamp'] as String),
      );

      // Emit to UI stream only — the background isolate already persisted
      // this location to Hive and uploaded it to Firestore.
      _locationStreamController.add(location);

      // Telemetry only (no Hive save, no upload trigger here).
      _writeTelemetry('location_received', {
        'lat': lat,
        'lng': lng,
        'accuracy': accuracy,
      });
    } catch (e) {
      AppLogger.error('REPO', 'Error processing location event', e);
    }
  }

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
      await uploadPendingLocations();
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

    controller.onListen = () async {
      try {
        final permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          AppLogger.warn(
              'REPO', 'Foreground stream: permission not granted — skipping seed fix');
          return;
        }

        final serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) {
          AppLogger.warn('REPO', 'Foreground stream: location services disabled');
          return;
        }

        final seed = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 10),
        );
        if (!controller.isClosed) {
          controller.add(DriverLocation(
            id: _uuid.v4(),
            latitude: seed.latitude,
            longitude: seed.longitude,
            accuracy: seed.accuracy,
            heading: seed.heading,
            speed: seed.speed,
            timestamp: seed.timestamp,
          ));
          AppLogger.info(
            'REPO',
            'Foreground seed fix: '
                'lat=${seed.latitude.toStringAsFixed(6)} '
                'lng=${seed.longitude.toStringAsFixed(6)} '
                'acc=${seed.accuracy.toStringAsFixed(1)}m',
          );
        }
      } catch (e) {
        AppLogger.warn('REPO', 'Foreground seed fix failed: $e');
      }

      if (!controller.isClosed) {
        try {
          final permission = await Geolocator.checkPermission();
          if (permission == LocationPermission.denied ||
              permission == LocationPermission.deniedForever) {
            return;
          }
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 5,
            ),
          ).listen(
            (pos) {
              if (!controller.isClosed) {
                controller.add(DriverLocation(
                  id: _uuid.v4(),
                  latitude: pos.latitude,
                  longitude: pos.longitude,
                  accuracy: pos.accuracy,
                  heading: pos.heading,
                  speed: pos.speed,
                  timestamp: pos.timestamp,
                ));
              }
            },
            onError: (Object e) {
              AppLogger.warn('REPO', 'Foreground position stream error: $e');
            },
            onDone: () {
              if (!controller.isClosed) controller.close();
            },
          );
        } catch (e) {
          AppLogger.warn('REPO', 'Could not start foreground position stream: $e');
        }
      }
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