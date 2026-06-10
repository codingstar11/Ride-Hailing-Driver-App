import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ride_hailing_driver/core/network/connectivity_service.dart';
import 'package:ride_hailing_driver/core/storage/hive_storage.dart';
import 'package:ride_hailing_driver/core/storage/location_entry.dart';
import 'package:ride_hailing_driver/core/storage/location_hive_datasource.dart';
import 'package:ride_hailing_driver/core/storage/telemetry_entry.dart';
import 'package:ride_hailing_driver/features/location/data/datasources/location_remote_datasource.dart';
import 'package:ride_hailing_driver/features/location/domain/entities/driver_location.dart';
import 'package:ride_hailing_driver/core/mock_api/mock_api_client.dart' hide MockApiClient;

import 'connectivity_recovery_test.mocks.dart';

@GenerateMocks([ConnectivityService, ApiClient])
void main() {
  late Directory tempDir;
  late LocationHiveDatasource datasource;
  late MockApiClient mockApi;
  late LocationRemoteDatasource remoteDatasource;

  TestWidgetsFlutterBinding.ensureInitialized();

  /// Converts a [LocationEntry] to the [DriverLocation] entity that
  /// [LocationHiveDatasource.saveLocation] expects.
  DriverLocation _entryToDriverLoc(LocationEntry e) => DriverLocation(
        id: e.uuid,
        latitude: e.latitude,
        longitude: e.longitude,
        accuracy: e.accuracy,
        heading: e.heading,
        speed: e.speed,
        timestamp: e.timestamp,
      );

  /// Builds a minimal [LocationEntry] for testing.
  LocationEntry _makeEntry(String uuid, String tripId) => LocationEntry(
        uuid: uuid,
        tripId: tripId,
        latitude: 33.6844 + uuid.hashCode * 0.0001,
        longitude: 73.0479 + uuid.hashCode * 0.0001,
        accuracy: 10.0,
        heading: 0.0,
        speed: 5.0,
        timestamp: DateTime.now(),
      );

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('connectivity_test_');
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
    mockApi = MockApiClient();
    remoteDatasource = LocationRemoteDatasource(mockApi);
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

  group('Connectivity Recovery', () {
    test(
        'locations queued while offline are uploaded when connectivity is restored',
        () async {
      const tripId = 'TRIP_OFFLINE_TEST';

      // Save 3 locations to Hive (simulating offline accumulation).
      final entries = [
        _makeEntry('uuid-1', tripId),
        _makeEntry('uuid-2', tripId),
        _makeEntry('uuid-3', tripId),
      ];
      for (final e in entries) {
        await datasource.saveLocation(_entryToDriverLoc(e), tripId);
      }

      // All three should be pending before upload.
      final pendingBefore =
          await datasource.getPendingLocations(tripId: tripId, limit: 10);
      expect(pendingBefore.length, 3,
          reason: 'All locations must survive until confirmed ACK');

      // Simulate connectivity restoration: server ACKs all submitted UUIDs.
      when(mockApi.uploadLocationBatch(
        tripId: anyNamed('tripId'),
        locations: anyNamed('locations'),
      )).thenAnswer((inv) async {
        final locs =
            inv.namedArguments[const Symbol('locations')] as List<LocationEntry>;
        return locs.map((e) => e.uuid).toList();
      });

      final pending =
          await datasource.getPendingLocations(tripId: tripId, limit: 50);
      final ackIds = await remoteDatasource.uploadLocationBatch(
        locations: pending,
        tripId: tripId,
      );
      await datasource.deleteConfirmed(ackIds);

      final pendingAfter =
          await datasource.getPendingLocations(tripId: tripId, limit: 10);
      expect(pendingAfter.length, 0,
          reason: 'Queue must be empty after all entries are ACKed');
      expect(ackIds.length, 3);
    });

    test('locations from different trips are not mixed on recovery', () async {
      const tripA = 'TRIP_A';
      const tripB = 'TRIP_B';

      await datasource.saveLocation(_entryToDriverLoc(_makeEntry('a1', tripA)), tripA);
      await datasource.saveLocation(_entryToDriverLoc(_makeEntry('a2', tripA)), tripA);
      await datasource.saveLocation(_entryToDriverLoc(_makeEntry('b1', tripB)), tripB);

      final pendingA =
          await datasource.getPendingLocations(tripId: tripA, limit: 10);
      final pendingB =
          await datasource.getPendingLocations(tripId: tripB, limit: 10);

      expect(pendingA.length, 2);
      expect(pendingB.length, 1);
      expect(pendingA.every((e) => e.tripId == tripA), isTrue);
      expect(pendingB.every((e) => e.tripId == tripB), isTrue);
    });

    test('partial ACK leaves non-ACKed entries in the queue', () async {
      const tripId = 'TRIP_PARTIAL_ACK';

      for (var i = 1; i <= 5; i++) {
        await datasource.saveLocation(
          _entryToDriverLoc(_makeEntry('uuid-$i', tripId)),
          tripId,
        );
      }

      // Server ACKs only the first two.
      await datasource.deleteConfirmed(['uuid-1', 'uuid-2']);

      final remaining =
          await datasource.getPendingLocations(tripId: tripId, limit: 10);
      expect(remaining.length, 3,
          reason: 'Non-ACKed entries must remain in queue for retry');
      expect(remaining.map((e) => e.uuid),
          containsAllInOrder(['uuid-3', 'uuid-4', 'uuid-5']));
    });

    test('retry count increments on failure and entry stays in queue', () async {
      const tripId = 'TRIP_RETRY';
      await datasource.saveLocation(
        _entryToDriverLoc(_makeEntry('retry-uuid', tripId)),
        tripId,
      );

      await datasource.incrementRetry('retry-uuid');
      await datasource.incrementRetry('retry-uuid');

      final pending =
          await datasource.getPendingLocations(tripId: tripId, limit: 10);
      expect(pending.length, 1,
          reason: 'Failed entry must remain in queue for retry');
      expect(pending.first.retryCount, 2);
    });
  });
}