import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:logger/logger.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../constants/app_constants.dart';
import 'hive_storage.dart';
import 'location_entry.dart';
import 'telemetry_entry.dart';
import '../../features/location/domain/entities/driver_location.dart';

/// Datasource that reads/writes GPS location data using Hive.
///
class LocationHiveDatasource {
  final _logger = Logger();
  final _uuid = const Uuid();

  // BehaviorSubject drives the pending count badge without polling.
  final _pendingCountSubject = BehaviorSubject<int>.seeded(0);

  Stream<int> get pendingCountStream => _pendingCountSubject.stream;

  // ── Write ────────────────────────────────────────────────────────────────

  Future<void> saveLocation(DriverLocation location, String tripId) async {
    final box = HiveStorage.locationQueue;
    final key = location.id.isEmpty ? _uuid.v4() : location.id;

    final entry = LocationEntry(
      uuid: key,
      latitude: location.latitude,
      longitude: location.longitude,
      accuracy: location.accuracy,
      heading: location.heading,
      speed: location.speed,
      timestamp: location.timestamp,
      tripId: tripId,
    );

    await box.put(key, entry);
   
    await box.flush();

    _logger.d('[HiveDS] Saved + flushed location $key (trip: $tripId)');

    // Track the latest location key per trip for O(1) restoration.
    await _setLatestLocationKey(tripId, key);

    _refreshCount();

    // Write telemetry non-blocking — failures must not affect the main flow.
    _writeTelemetry(
      event: 'location_saved',
      tripId: tripId,
      extra: {
        'uuid': key,
        'lat': location.latitude,
        'lng': location.longitude,
        'accuracy': location.accuracy,
      },
    );
  }

  // ── Read ─────────────────────────────────────────────────────────────────

  /// Returns up to [limit] pending entries in insertion order.
  ///
  /// LazyBox.keys preserves insertion order. We load values lazily to
  /// avoid pulling the entire queue into memory on large backlogs.
  Future<List<LocationEntry>> getPendingLocations({
    required String tripId,
    int limit = AppConstants.batchUploadSize,
  }) async {
    final box = HiveStorage.locationQueue;
    final allKeys = box.keys.toList();
    final result = <LocationEntry>[];

    for (final key in allKeys) {
      if (result.length >= limit) break;
      final entry = await box.get(key);
      if (entry != null && entry.tripId == tripId) {
        result.add(entry);
      }
    }

    return result;
  }

  /// Returns the single most-recent [LocationEntry] for [tripId], or null.
  Future<LocationEntry?> getLatestLocation({required String tripId}) async {
    final key = _latestLocationKey(tripId);
    final latestUuid = HiveStorage.activeTrip.get(key)?['uuid'] as String?;
    if (latestUuid == null) return null;
    return HiveStorage.locationQueue.get(latestUuid);
  }

  /// Returns all pending entries regardless of trip — used for recovery scan.
  Future<List<LocationEntry>> recoverPendingFromPreviousSession() async {
    final box = HiveStorage.locationQueue;
    final all = <LocationEntry>[];
    for (final key in box.keys) {
      final entry = await box.get(key);
      if (entry != null) all.add(entry);
    }
    _logger.i(
        '[HiveDS] Recovered ${all.length} pending entries from previous session');
    return all;
  }

  Future<int> getPendingCount({String? tripId}) async {
    if (tripId == null) return HiveStorage.locationQueue.length;

    final box = HiveStorage.locationQueue;
    int count = 0;
    for (final key in box.keys) {
      final entry = await box.get(key);
      if (entry != null && entry.tripId == tripId) count++;
    }
    return count;
  }

  // ── Delete on ACK ────────────────────────────────────────────────────────

  Future<void> deleteConfirmed(List<String> uuids) async {
    final box = HiveStorage.locationQueue;
    await box.deleteAll(uuids);
    await box.flush();
    _logger.d('[HiveDS] Deleted + flushed ${uuids.length} confirmed entries');

    _writeTelemetry(
      event: 'locations_confirmed',
      tripId: uuids.isNotEmpty ? 'batch' : 'empty',
      extra: {'count': uuids.length},
    );

    _refreshCount();
  }

  // ── Increment retry count ────────────────────────────────────────────────

  Future<void> incrementRetry(String uuid) async {
    final box = HiveStorage.locationQueue;
    final entry = await box.get(uuid);
    if (entry == null) return;
    entry.retryCount += 1;
    await box.put(uuid, entry);
    // No flush needed here — retry count updates are advisory, not critical.
  }

  // ── Cleanup ──────────────────────────────────────────────────────────────

  Future<void> cleanupStaleEntries(
      {int retentionDays = AppConstants.uploadedRecordRetentionDays}) async {
    final cutoff = DateTime.now().subtract(Duration(days: retentionDays));
    final box = HiveStorage.locationQueue;
    final staleKeys = <dynamic>[];

    for (final key in box.keys) {
      final entry = await box.get(key);
      if (entry != null && entry.timestamp.isBefore(cutoff)) {
        staleKeys.add(key);
      }
    }

    if (staleKeys.isNotEmpty) {
      await box.deleteAll(staleKeys);
      await box.flush();
      _logger.i('[HiveDS] Cleaned up ${staleKeys.length} stale entries');
    }
  }

  // ── Active trip persistence ──────────────────────────────────────────────

  Future<void> saveActiveTrip(String tripId) async {
    final record = {
      'trip_id': tripId,
      'started_at': DateTime.now().toIso8601String(),
    };

    final box = HiveStorage.activeTrip;
    await box.put('current', record);
    // Flush immediately so this record survives a process kill.
    // This is the most critical flush in the entire codebase — without it,
    // every app relaunch after being killed loses the active trip and the
    // driver sees "Start Trip" instead of the active trip being restored.
    await box.flush();

    // Mirror to SharedPreferences as a secondary durability guarantee.
    // SharedPreferences writes through to disk immediately (commit() on Android,
    // NSUserDefaults synchronize() on iOS). This is the fallback read path in
    // getActiveTripId() for the case where the Hive flush was somehow still
    // delayed (e.g. very rapid kill immediately after put()).
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('active_trip_id', tripId);
    await prefs.setString(
      'active_trip_started_at',
      record['started_at'] as String,
    );

    _logger.i('[HiveDS] Active trip saved + flushed: $tripId');
  }

  /// Returns the active trip ID, checking Hive first then SharedPreferences.
  ///
  /// Two-source read is necessary because Hive's flush is asynchronous:
  /// if the process was killed before Hive flushed its write buffer, the
  /// activeTrip box will be empty on the next launch even though saveActiveTrip
  /// was called. SharedPreferences flushes synchronously, so it is always
  /// the authoritative fallback.
  Future<String?> getActiveTripId() async {
    // Primary: Hive (fast, in-memory once box is open)
    final data = HiveStorage.activeTrip.get('current');
    final tripIdFromHive = data?['trip_id'] as String?;
    if (tripIdFromHive != null && tripIdFromHive.isNotEmpty) {
      return tripIdFromHive;
    }

    // Fallback: SharedPreferences
    // This path is taken when Hive was not flushed before the last kill.
    final prefs = await SharedPreferences.getInstance();
    final tripIdFromPrefs = prefs.getString('active_trip_id');
    if (tripIdFromPrefs != null && tripIdFromPrefs.isNotEmpty) {
      _logger.w(
        '[HiveDS] Active trip recovered from SharedPreferences fallback '
        '(Hive was not flushed before last kill)  trip=$tripIdFromPrefs',
      );
      // Re-write to Hive so subsequent reads hit the fast path.
      // Do NOT await — this is a best-effort repair; we don't want to
      // block the caller on this recovery write.
      _repairActiveTripInHive(tripIdFromPrefs);
      return tripIdFromPrefs;
    }

    return null;
  }

  /// Re-writes the active trip record to Hive after recovering it from
  /// SharedPreferences. Runs asynchronously so it doesn't block the caller.
  Future<void> _repairActiveTripInHive(String tripId) async {
    try {
      final box = HiveStorage.activeTrip;
      await box.put('current', {
        'trip_id': tripId,
        'started_at': (await SharedPreferences.getInstance())
                .getString('active_trip_started_at') ??
            DateTime.now().toIso8601String(),
      });
      await box.flush();
      _logger.i('[HiveDS] Repaired Hive active trip record  trip=$tripId');
    } catch (e) {
      _logger.w('[HiveDS] Failed to repair Hive active trip: $e');
    }
  }

  Future<void> clearActiveTrip() async {
    final box = HiveStorage.activeTrip;
    await box.delete('current');
    await box.flush();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('active_trip_id');
    await prefs.remove('active_trip_started_at');

    _logger.i('[HiveDS] Active trip cleared from Hive + SharedPreferences');
  }

  // ── Completed trip archive ───────────────────────────────────────────────

  Future<void> archiveCompletedTrip(Map<String, dynamic> tripSummary) async {
    final tripId = tripSummary['trip_id'] as String;
    await HiveStorage.completedTrips.put(tripId, tripSummary);
    // No flush needed — completed trip archives are advisory, not critical.
    _logger.i('[HiveDS] Archived completed trip: $tripId');
  }

  // ── Telemetry ────────────────────────────────────────────────────────────

  Future<void> writeTelemetryEvent({
    required String event,
    required String tripId,
    Map<String, dynamic> extra = const {},
  }) =>
      _writeTelemetry(event: event, tripId: tripId, extra: extra);

  Future<void> _writeTelemetry({
    required String event,
    required String tripId,
    Map<String, dynamic> extra = const {},
  }) async {
    try {
      final entry = TelemetryEntry(
        event: event,
        tripId: tripId,
        payload: jsonEncode(extra),
        timestamp: DateTime.now(),
      );
      final key = '${DateTime.now().millisecondsSinceEpoch}_$event';
      await HiveStorage.telemetry.put(key, entry);
      // Telemetry writes are NOT flushed — they are advisory. If the process
      // is killed before Hive flushes, losing a few telemetry entries is acceptable.
    } catch (e) {
      _logger.w('[HiveDS] Telemetry write failed: $e');
    }
  }

  // ── Latest location tracking ─────────────────────────────────────────────

  Future<void> _setLatestLocationKey(String tripId, String uuid) async {
    final box = HiveStorage.activeTrip;
    await box.put(_latestLocationKey(tripId), {'uuid': uuid});
    await box.flush();
  }

  static String _latestLocationKey(String tripId) => 'latest_loc:$tripId';

  // ── Reactive count ───────────────────────────────────────────────────────

  void _refreshCount() {
    _pendingCountSubject.add(HiveStorage.locationQueue.length);
  }

  void dispose() {
    _pendingCountSubject.close();
  }
}
