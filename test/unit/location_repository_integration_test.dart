import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ride_hailing_driver/core/mock_api/mock_api_client.dart' hide MockApiClient;
import 'package:ride_hailing_driver/core/network/connectivity_service.dart';
import 'package:ride_hailing_driver/core/storage/hive_storage.dart';
import 'package:ride_hailing_driver/core/storage/location_entry.dart';
import 'package:ride_hailing_driver/core/storage/location_hive_datasource.dart';
import 'package:ride_hailing_driver/core/storage/telemetry_entry.dart';
import 'package:ride_hailing_driver/features/location/data/datasources/location_remote_datasource.dart';
import 'package:ride_hailing_driver/features/location/domain/entities/driver_location.dart';

import 'location_repository_integration_test.mocks.dart';

@GenerateMocks([ApiClient, ConnectivityService])
void main() {
  late Directory tempDir;
  late LocationHiveDatasource localDatasource;
  late MockApiClient mockApi;
  late LocationRemoteDatasource remoteDatasource;

  TestWidgetsFlutterBinding.ensureInitialized();

  DriverLocation _makeLocation(String id, {double accuracy = 15.0}) =>
      DriverLocation(
        id: id,
        latitude: 33.6844,
        longitude: 73.0479,
        accuracy: accuracy,
        heading: 45.0,
        speed: 8.0,
        timestamp: DateTime.now(),
      );

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('repo_integration_');
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
    localDatasource = LocationHiveDatasource();
    mockApi = MockApiClient();
    remoteDatasource = LocationRemoteDatasource(mockApi);
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk(HiveStorage.locationQueueBox);
    await Hive.deleteBoxFromDisk(HiveStorage.activeTripBox);
    await Hive.deleteBoxFromDisk(HiveStorage.completedTripsBox);
    await Hive.deleteBoxFromDisk(HiveStorage.configBox);
    await Hive.deleteBoxFromDisk(HiveStorage.telemetryBox);
    localDatasource.dispose();
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  group('Critical path: saveLocation → uploadPendingLocations', () {
    test(
        'location saved to Hive first, then uploaded and removed on ACK',
        () async {
      const tripId = 'TRIP_CRITICAL_PATH';
      final loc = _makeLocation('loc-001');

      await localDatasource.saveLocation(loc, tripId);

      final pendingBeforeUpload =
          await localDatasource.getPendingLocations(tripId: tripId, limit: 10);
      expect(pendingBeforeUpload.length, 1,
          reason: 'Location must be in Hive before upload is attempted');

      when(mockApi.uploadLocationBatch(
        tripId: anyNamed('tripId'),
        locations: anyNamed('locations'),
      )).thenAnswer((inv) async {
        final locs =
            inv.namedArguments[const Symbol('locations')] as List<LocationEntry>;
        return locs.map((e) => e.uuid).toList();
      });

      final pending =
          await localDatasource.getPendingLocations(tripId: tripId, limit: 50);
      final ackIds = await remoteDatasource.uploadLocationBatch(
        locations: pending,
        tripId: tripId,
      );

      await localDatasource.deleteConfirmed(ackIds);

      final pendingAfter =
          await localDatasource.getPendingLocations(tripId: tripId, limit: 10);
      expect(pendingAfter.length, 0,
          reason: 'Queue must be empty after server ACK');
    });

    test('upload order is preserved: oldest location uploaded first', () async {
      const tripId = 'TRIP_ORDER';
      final uploadOrder = <String>[];

      for (var i = 1; i <= 5; i++) {
        await localDatasource.saveLocation(_makeLocation('loc-$i'), tripId);
        await Future.delayed(const Duration(milliseconds: 5));
      }

      when(mockApi.uploadLocationBatch(
        tripId: anyNamed('tripId'),
        locations: anyNamed('locations'),
      )).thenAnswer((inv) async {
        final locs =
            inv.namedArguments[const Symbol('locations')] as List<LocationEntry>;
        uploadOrder.addAll(locs.map((e) => e.uuid));
        return locs.map((e) => e.uuid).toList();
      });

      final pending =
          await localDatasource.getPendingLocations(tripId: tripId, limit: 50);
      await remoteDatasource.uploadLocationBatch(
        locations: pending,
        tripId: tripId,
      );

      expect(uploadOrder, equals(['loc-1', 'loc-2', 'loc-3', 'loc-4', 'loc-5']),
          reason: 'Locations must be uploaded in insertion order (oldest first)');
    });

    test('failed upload leaves all entries in queue for retry', () async {
      const tripId = 'TRIP_FAIL';
      for (var i = 1; i <= 3; i++) {
        await localDatasource.saveLocation(_makeLocation('fail-$i'), tripId);
      }

      when(mockApi.uploadLocationBatch(
        tripId: anyNamed('tripId'),
        locations: anyNamed('locations'),
      )).thenThrow(Exception('server unavailable'));

      final pending =
          await localDatasource.getPendingLocations(tripId: tripId, limit: 50);

      try {
        await remoteDatasource.uploadLocationBatch(
            locations: pending, tripId: tripId);
        fail('Expected exception was not thrown');
      } catch (e) {
        for (final entry in pending) {
          await localDatasource.incrementRetry(entry.uuid);
        }
      }

      final stillPending =
          await localDatasource.getPendingLocations(tripId: tripId, limit: 10);
      expect(stillPending.length, 3,
          reason: 'All entries must survive a failed upload for retry');
      expect(stillPending.every((e) => e.retryCount == 1), isTrue);
    });

    test('batch size is respected — only batchSize entries are fetched', () async {
      const tripId = 'TRIP_BATCH';
      for (var i = 1; i <= 20; i++) {
        await localDatasource.saveLocation(_makeLocation('batch-$i'), tripId);
      }

      final batch =
          await localDatasource.getPendingLocations(tripId: tripId, limit: 10);
      expect(batch.length, 10,
          reason: 'getPendingLocations must respect the limit parameter');
    });

    test('reportTripStarted is called with correct tripId', () async {
      const tripId = 'TRIP_REPORT_START';
      when(mockApi.reportTripStarted(any)).thenAnswer((_) async {});

      await remoteDatasource.reportTripStarted(tripId);

      verify(mockApi.reportTripStarted(tripId)).called(1);
    });

    test('reportTripEnded is called with correct tripId and point count',
        () async {
      const tripId = 'TRIP_REPORT_END';
      when(mockApi.reportTripEnded(
        tripId: anyNamed('tripId'),
        totalPoints: anyNamed('totalPoints'),
      )).thenAnswer((_) async {});

      await remoteDatasource.reportTripEnded(tripId: tripId, totalPoints: 42);

      verify(mockApi.reportTripEnded(tripId: tripId, totalPoints: 42)).called(1);
    });
  });
}