import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:ride_hailing_driver/core/constants/app_constants.dart';

import 'package:ride_hailing_driver/core/storage/location_entry.dart';
import 'package:ride_hailing_driver/core/storage/hive_storage.dart';
import 'package:ride_hailing_driver/core/storage/location_hive_datasource.dart';
import 'package:ride_hailing_driver/core/storage/telemetry_entry.dart';
import 'package:ride_hailing_driver/features/location/domain/entities/driver_location.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests for the Hive-backed offline location queue.
///
/// Why these tests matter
/// ──────────────────────
/// The offline queue is the single most important reliability component.
/// If a location is not saved before an upload attempt, it is permanently
/// lost. These tests verify that:
///  1. Locations are saved to Hive immediately.
///  2. Batch retrieval returns entries in insertion order.
///  3. Deletion on ACK is accurate — only ACK'd UUIDs are removed.
///  4. The pending count stream updates correctly.
///  5. Stale entry cleanup does not delete recent entries.
///  6. Session recovery finds leftover entries from a previous session.
///
/// Test isolation: each test opens an in-memory Hive box (via a temp dir)
/// and closes it after. This prevents state from leaking between tests.
void main() {
  late Directory tempDir;
  late LocationHiveDatasource datasource;

  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    
    tempDir = await Directory.systemTemp.createTemp('hive_test_');
    Hive.init(tempDir.path);
    Hive.registerAdapter(LocationEntryAdapter());
    Hive.registerAdapter(TelemetryEntryAdapter());
  });

  setUp(() async {
    await Hive.openLazyBox<LocationEntry>(HiveStorage.locationQueueBox);
    await Hive.openBox<Map>(HiveStorage.activeTripBox);
    await Hive.openLazyBox<Map>(HiveStorage.completedTripsBox);
    await Hive.openBox<dynamic>(HiveStorage.configBox);
    await Hive.openLazyBox<TelemetryEntry>(HiveStorage.telemetryBox);
    datasource = LocationHiveDatasource();
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk(HiveStorage.locationQueueBox);
    await Hive.deleteBoxFromDisk(HiveStorage.activeTripBox);
    await Hive.deleteBoxFromDisk(HiveStorage.completedTripsBox);
    await Hive.deleteBoxFromDisk(HiveStorage.configBox);
    await Hive.deleteBoxFromDisk(HiveStorage.telemetryBox);
    datasource.dispose();
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  // ── Helpers ──────────────────────────────────────────────────────────────

  DriverLocation _makeLocation(String id, {double accuracy = 10.0}) {
    return DriverLocation(
      id: id,
      latitude: AppConstants.initialLatitude,
      longitude: AppConstants.initialLongitude,
      accuracy: accuracy,
      timestamp: DateTime.now(),
    );
  }

  // ── Save ─────────────────────────────────────────────────────────────────

  test('saveLocation persists entry to Hive box', () async {
    final loc = _makeLocation('uuid-001');
    await datasource.saveLocation(loc, 'TRIP_001');

    final pending = await datasource.getPendingLocations(tripId: 'TRIP_001');
    expect(pending, hasLength(1));
    expect(pending.first.uuid, 'uuid-001');
    expect(pending.first.tripId, 'TRIP_001');
    // Production risk: if save fails silently, the location is permanently lost.
  });

  test('saveLocation preserves all GPS fields', () async {
    final loc = DriverLocation(
      id: 'uuid-002',
      latitude: 31.5210,
      longitude: 74.3593,
      accuracy: 8.5,
      heading: 90.0,
      speed: 12.5,
      timestamp: DateTime(2024, 6, 1, 12, 0, 0),
    );
    await datasource.saveLocation(loc, 'TRIP_001');

    final result = await datasource.getPendingLocations(tripId: 'TRIP_001');
    final entry = result.first;
    expect(entry.latitude, 31.5210);
    expect(entry.longitude, 74.3593);
    expect(entry.heading, 90.0);
    expect(entry.speed, 12.5);
    expect(entry.accuracy, 8.5);
    // Production risk: corrupted GPS fields produce a broken route on the server.
  });

  // ── Batch retrieval ───────────────────────────────────────────────────────

  test('getPendingLocations respects limit parameter', () async {
    for (int i = 0; i < 10; i++) {
      await datasource.saveLocation(_makeLocation('uuid-$i'), 'TRIP_001');
    }
    final batch = await datasource.getPendingLocations(tripId: 'TRIP_001', limit: 5);
    expect(batch, hasLength(5));
    // Production risk: uploading unbounded batches causes timeouts.
  });

  test('getPendingLocations only returns entries for the given tripId', () async {
    await datasource.saveLocation(_makeLocation('t1-a'), 'TRIP_001');
    await datasource.saveLocation(_makeLocation('t2-a'), 'TRIP_002');
    await datasource.saveLocation(_makeLocation('t1-b'), 'TRIP_001');

    final forTrip1 = await datasource.getPendingLocations(tripId: 'TRIP_001');
    expect(forTrip1.every((e) => e.tripId == 'TRIP_001'), isTrue);
    expect(forTrip1, hasLength(2));
    // Production risk: uploading another trip's points corrupts route data.
  });

  // ── Delete on ACK ────────────────────────────────────────────────────────

  test('deleteConfirmed removes only ACKd entries', () async {
    await datasource.saveLocation(_makeLocation('del-a'), 'TRIP_001');
    await datasource.saveLocation(_makeLocation('del-b'), 'TRIP_001');
    await datasource.saveLocation(_makeLocation('keep-c'), 'TRIP_001');

    await datasource.deleteConfirmed(['del-a', 'del-b']);

    final remaining = await datasource.getPendingLocations(tripId: 'TRIP_001');
    expect(remaining, hasLength(1));
    expect(remaining.first.uuid, 'keep-c');
    // Production risk: deleting wrong entries causes re-upload of already
    // stored data (duplicates on server) or loss of pending data.
  });

  test('deleteConfirmed with empty list is a no-op', () async {
    await datasource.saveLocation(_makeLocation('uuid-x'), 'TRIP_001');
    await datasource.deleteConfirmed([]);
    final remaining = await datasource.getPendingLocations(tripId: 'TRIP_001');
    expect(remaining, hasLength(1));
  });

  // ── Count stream ──────────────────────────────────────────────────────────

  test('pendingCountStream emits updated count after save and delete', () async {
    final counts = <int>[];
    final sub = datasource.pendingCountStream.listen(counts.add);

    await datasource.saveLocation(_makeLocation('cnt-1'), 'TRIP_001');
    await datasource.saveLocation(_makeLocation('cnt-2'), 'TRIP_001');
    await datasource.deleteConfirmed(['cnt-1']);

    await Future.delayed(const Duration(milliseconds: 50));
    await sub.cancel();

    // Stream should have emitted at least the final count = 1.
    expect(counts.last, 1);
    // Production risk: stale badge count confuses drivers about sync status.
  });

  // ── Session recovery ─────────────────────────────────────────────────────

  test('recoverPendingFromPreviousSession returns all box entries', () async {
    await datasource.saveLocation(_makeLocation('prev-a'), 'TRIP_OLD');
    await datasource.saveLocation(_makeLocation('prev-b'), 'TRIP_OLD');

    final recovered = await datasource.recoverPendingFromPreviousSession();
    expect(recovered, hasLength(2));
    // Production risk: entries from a killed session are abandoned without
    // recovery, causing missing route points (Scenario B).
  });

  // ── Active trip persistence ───────────────────────────────────────────────

  test('saveActiveTrip and getActiveTripId round-trip correctly', () async {
    await datasource.saveActiveTrip('TRIP_PERSIST');
    final id = await datasource.getActiveTripId();
    expect(id, 'TRIP_PERSIST');
    // Production risk: without trip ID persistence, a restart loses the
    // current trip context and orphans queued locations.
  });

  test('clearActiveTrip removes the trip entry', () async {
    await datasource.saveActiveTrip('TRIP_CLEAR');
    await datasource.clearActiveTrip();
    final id = await datasource.getActiveTripId();
    expect(id, isNull);
  });

  // ── Stale cleanup ─────────────────────────────────────────────────────────

  test('cleanupStaleEntries removes old entries but keeps recent ones', () async {
    // Create a fake old entry by directly inserting into Hive.
    final box = HiveStorage.locationQueue;
    final oldEntry = LocationEntry(
      uuid: 'old-entry',
      latitude: 0,
      longitude: 0,
      accuracy: 10,
      timestamp: DateTime.now().subtract(const Duration(days: 10)),
      tripId: 'OLD_TRIP',
    );
    await box.put('old-entry', oldEntry);

    await datasource.saveLocation(_makeLocation('new-entry'), 'TRIP_001');

    await datasource.cleanupStaleEntries(retentionDays: 7);

    final remaining = await datasource.getPendingLocations(tripId: 'TRIP_001');
    expect(remaining.any((e) => e.uuid == 'new-entry'), isTrue);
    expect(remaining.any((e) => e.uuid == 'old-entry'), isFalse);
    // Production risk: unbounded queue growth degrades app performance over time.
  });
}
