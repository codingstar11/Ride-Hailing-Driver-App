import 'dart:convert';
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
/// Responsibilities:
///  1. Persist incoming GPS locations to the 'location_queue' LazyBox.
///  2. Retrieve batches of pending entries for upload.
///  3. Delete confirmed entries (server ACK removes from queue permanently).
///  4. Expose a reactive count stream so the UI badge updates in real time.
///  5. Write telemetry events for diagnosability.
///
/// Offline-first guarantee: saveLocation() completes before any network
/// call is attempted. If the process is killed after save but before upload,
/// the entry is still in the Hive box and will be retried on next launch.
///
/// Synchronisation after restart: [recoverPendingFromPreviousSession] scans
/// all keys in the box. Any entry whose tripId matches the resumed trip is
/// eligible for re-upload. Entries from a different (ended) trip are
/// cleaned up after a configurable retention window.
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

    // Use the UUID as the Hive key for O(1) deletion on ACK.
    await box.put(key, entry);
    _logger.d('[HiveDS] Saved location $key (trip: $tripId)');

    await _writeTelemetry(
      event: 'location_saved',
      tripId: tripId,
      extra: {
        'uuid': key,
        'lat': location.latitude,
        'lng': location.longitude,
        'accuracy': location.accuracy,
      },
    );

    // Track the latest location key per trip for O(1) restoration.
    await _setLatestLocationKey(tripId, key);

    _refreshCount();
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
  ///
  /// Uses a dedicated 'latest_location_key:<tripId>' entry in the activeTrip
  /// box to track the UUID of the last saved point.  This avoids the previous
  /// O(n) scan (loading up to 500 entries and taking `.last`) in
  /// [LocationRepositoryImpl._emitLatestSavedLocation].
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

  /// Removes entries confirmed by the server (ACK list = list of UUIDs).
  ///
  /// Deletion instead of marking: keeps the box small, avoids a separate
  /// 'cleanup' sweep, and means the count badge is always accurate.
  Future<void> deleteConfirmed(List<String> uuids) async {
    final box = HiveStorage.locationQueue;
    await box.deleteAll(uuids);
    _logger.d('[HiveDS] Deleted ${uuids.length} confirmed entries');

    await _writeTelemetry(
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
  }

  // ── Cleanup ──────────────────────────────────────────────────────────────

  /// Removes entries older than [retentionDays] from any trip.
  /// Called when a trip ends to prevent indefinite accumulation.
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
      _logger.i('[HiveDS] Cleaned up ${staleKeys.length} stale entries');
    }
  }

  // ── Active trip persistence ──────────────────────────────────────────────

  Future<void> saveActiveTrip(String tripId) async {
    await HiveStorage.activeTrip.put('current', {
      'trip_id': tripId,
      'started_at': DateTime.now().toIso8601String(),
    });
    // Mirror to SharedPreferences so BootReceiver can read it
    // before Flutter initialises on reboot.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('active_trip_id', tripId);
    _logger.i('[HiveDS] Active trip saved: $tripId');
  }

  Future<String?> getActiveTripId() async {
    final data = HiveStorage.activeTrip.get('current');
    return data?['trip_id'] as String?;
  }

  Future<void> clearActiveTrip() async {
    await HiveStorage.activeTrip.delete('current');
    // Clear the mirror so BootReceiver does not restart after trip ends.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('active_trip_id');
  }

  // ── Completed trip archive ───────────────────────────────────────────────

  Future<void> archiveCompletedTrip(Map<String, dynamic> tripSummary) async {
    final tripId = tripSummary['trip_id'] as String;
    await HiveStorage.completedTrips.put(tripId, tripSummary);
    _logger.i('[HiveDS] Archived completed trip: $tripId');
  }

  // ── Telemetry ────────────────────────────────────────────────────────────

  /// Public entry-point so [LocationRepositoryImpl] can persist telemetry
  /// events from the repository layer (e.g. connectivity changes, trip
  /// lifecycle, upload results) to the same Hive telemetry box.
  ///
  /// Previously the repository's _writeTelemetry() only called AppLogger and
  /// discarded the data.  Now all critical events are durably persisted.
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
      // Key = timestamp + event for chronological ordering.
      final key = '${DateTime.now().millisecondsSinceEpoch}_$event';
      await HiveStorage.telemetry.put(key, entry);
    } catch (e) {
      // Telemetry must never crash the main flow.
      _logger.w('[HiveDS] Telemetry write failed: $e');
    }
  }

  // ── Latest location tracking ─────────────────────────────────────────────

  /// Stores the UUID of the most recently saved location for [tripId] so it
  /// can be retrieved in O(1) without scanning the full queue.
  Future<void> _setLatestLocationKey(String tripId, String uuid) async {
    await HiveStorage.activeTrip
        .put(_latestLocationKey(tripId), {'uuid': uuid});
  }

  /// Key used in the activeTrip box to look up the latest location UUID.
  static String _latestLocationKey(String tripId) => 'latest_loc:$tripId';

  // ── Reactive count ───────────────────────────────────────────────────────

  void _refreshCount() {
    _pendingCountSubject.add(HiveStorage.locationQueue.length);
  }

  void dispose() {
    _pendingCountSubject.close();
  }
}
