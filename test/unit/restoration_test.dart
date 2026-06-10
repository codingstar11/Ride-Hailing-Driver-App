import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ride_hailing_driver/core/storage/hive_storage.dart';
import 'package:ride_hailing_driver/core/storage/location_entry.dart';
import 'package:ride_hailing_driver/core/storage/location_hive_datasource.dart';
import 'package:ride_hailing_driver/core/storage/telemetry_entry.dart';
import 'package:ride_hailing_driver/features/location/domain/entities/driver_location.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests for app-restart trip restoration and location recovery.
void main() {
  late Directory tempDir;
  late LocationHiveDatasource datasource;

  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('hive_restore_test_');
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

  DriverLocation _makeLocation(String id, {double lat = 31.5, double lng = 74.3}) {
    return DriverLocation(
      id: id,
      latitude: lat,
      longitude: lng,
      accuracy: 10.0,
      timestamp: DateTime.now(),
    );
  }

  // ── Active trip persistence ──────────────────────────────────────────────

  test('active trip is persisted and restored across "restarts"', () async {
    await datasource.saveActiveTrip('TRIP_RESTORE');

    // Simulate fresh datasource (app restart)
    datasource.dispose();
    datasource = LocationHiveDatasource();

    final restored = await datasource.getActiveTripId();
    expect(restored, 'TRIP_RESTORE');
  });

  test('clearActiveTrip removes trip so restoration returns null', () async {
    await datasource.saveActiveTrip('TRIP_CLEAR');
    await datasource.clearActiveTrip();
    final id = await datasource.getActiveTripId();
    expect(id, isNull);
  });

  // ── Location restoration ─────────────────────────────────────────────────

  test('latest location is available from Hive after simulated restart', () async {
    final tripId = 'TRIP_LOC';
    await datasource.saveActiveTrip(tripId);

    for (int i = 1; i <= 5; i++) {
      await datasource.saveLocation(
        _makeLocation('loc-$i', lat: 31.5 + i * 0.001, lng: 74.3 + i * 0.001),
        tripId,
      );
    }

    // Simulate restart — new datasource instance.
    datasource.dispose();
    datasource = LocationHiveDatasource();

    final pending = await datasource.getPendingLocations(
      tripId: tripId,
      limit: 500,
    );
    expect(pending, hasLength(5));
    // Last entry has the highest sequence (most recent lat/lng).
    final latest = pending.last;
    expect(latest.latitude, closeTo(31.505, 0.001));
  });

  // ── Queue ordering preserved across restarts ──────────────────────────────

  test('insertion order is preserved across datasource restarts', () async {
    final tripId = 'TRIP_ORDER';
    final uuids = ['order-a', 'order-b', 'order-c'];

    for (final id in uuids) {
      await datasource.saveLocation(_makeLocation(id), tripId);
    }

    datasource.dispose();
    datasource = LocationHiveDatasource();

    final pending = await datasource.getPendingLocations(tripId: tripId);
    expect(pending.map((e) => e.uuid).toList(), equals(uuids));
  });

  // ── Session recovery ─────────────────────────────────────────────────────

  test('recoverPendingFromPreviousSession returns queued entries', () async {
    await datasource.saveLocation(_makeLocation('prev-1'), 'TRIP_PREV');
    await datasource.saveLocation(_makeLocation('prev-2'), 'TRIP_PREV');

    datasource.dispose();
    datasource = LocationHiveDatasource();

    final recovered = await datasource.recoverPendingFromPreviousSession();
    expect(recovered, hasLength(2));
    expect(recovered.every((e) => e.tripId == 'TRIP_PREV'), isTrue);
  });

  // ── Retry count persisted ────────────────────────────────────────────────

  test('incrementRetry persists retry count across datasource restarts', () async {
    await datasource.saveLocation(_makeLocation('retry-uuid'), 'TRIP_RETRY');
    await datasource.incrementRetry('retry-uuid');
    await datasource.incrementRetry('retry-uuid');

    datasource.dispose();
    datasource = LocationHiveDatasource();

    final entries = await datasource.getPendingLocations(tripId: 'TRIP_RETRY');
    expect(entries.first.retryCount, 2);
  });
}