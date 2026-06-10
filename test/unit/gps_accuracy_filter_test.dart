import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:ride_hailing_driver/core/storage/hive_storage.dart';
import 'package:ride_hailing_driver/core/storage/location_entry.dart';
import 'package:ride_hailing_driver/core/storage/location_hive_datasource.dart';
import 'package:ride_hailing_driver/core/storage/telemetry_entry.dart';
import 'package:ride_hailing_driver/features/location/domain/entities/driver_location.dart';

/// Tests for the GPS accuracy gate that prevents noisy fixes from entering
/// the offline queue.
///
/// The background service itself filters via [position.accuracy > accuracyThreshold]
/// before emitting. The repository applies a second check on receipt using
/// [CountryConfig.minAccuracyMeters]. These tests verify the Hive layer
/// correctly stores only the locations that pass the gate, and discards
/// those that don't — simulating what happens when the filter is enforced
/// before calling [LocationHiveDatasource.saveLocation].
void main() {
  late Directory tempDir;
  late LocationHiveDatasource datasource;

  DriverLocation _makeLocation({
    required String id,
    required double accuracy,
  }) =>
      DriverLocation(
        id: id,
        latitude: 33.6844,
        longitude: 73.0479,
        accuracy: accuracy,
        heading: 0.0,
        speed: 0.0,
        timestamp: DateTime.now(),
      );

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('accuracy_test_');
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

  const tripId = 'TRIP_ACCURACY_TEST';
  const accuracyThreshold = 50.0; // matches AppConstants / PK CountryConfig

  group('GPS Accuracy Filtering', () {
    test('location with accuracy <= threshold is saved to Hive', () async {
      final goodFix = _makeLocation(id: 'good-fix', accuracy: 20.0);

      // Apply the accuracy gate (mirrors what LocationRepositoryImpl does).
      if (goodFix.accuracy <= accuracyThreshold) {
        await datasource.saveLocation(goodFix, tripId);
      }

      final pending =
          await datasource.getPendingLocations(tripId: tripId, limit: 10);
      expect(pending.length, 1,
          reason: 'Accurate fix (20m) must be saved to the queue');
      expect(pending.first.uuid, 'good-fix');
    });

    test('location with accuracy > threshold is NOT saved to Hive', () async {
      final noisyFix = _makeLocation(id: 'noisy-fix', accuracy: 80.0);

      // Apply the accuracy gate — noisy fix must be discarded.
      if (noisyFix.accuracy <= accuracyThreshold) {
        await datasource.saveLocation(noisyFix, tripId);
      }

      final pending =
          await datasource.getPendingLocations(tripId: tripId, limit: 10);
      expect(pending.length, 0,
          reason: 'Noisy fix (80m > 50m threshold) must not enter the queue');
    });

    test('only accurate fixes are saved when a mix is received', () async {
      final fixes = [
        _makeLocation(id: 'fix-10m', accuracy: 10.0), // pass
        _makeLocation(id: 'fix-50m', accuracy: 50.0), // pass (boundary)
        _makeLocation(id: 'fix-51m', accuracy: 51.0), // fail
        _makeLocation(id: 'fix-100m', accuracy: 100.0), // fail
        _makeLocation(id: 'fix-25m', accuracy: 25.0), // pass
      ];

      for (final fix in fixes) {
        if (fix.accuracy <= accuracyThreshold) {
          await datasource.saveLocation(fix, tripId);
        }
      }

      final pending =
          await datasource.getPendingLocations(tripId: tripId, limit: 10);
      expect(pending.length, 3,
          reason: 'Only 3 of 5 fixes pass the 50m accuracy gate');
      expect(pending.map((e) => e.uuid),
          containsAll(['fix-10m', 'fix-50m', 'fix-25m']));
      expect(pending.map((e) => e.uuid),
          isNot(contains('fix-51m')));
      expect(pending.map((e) => e.uuid),
          isNot(contains('fix-100m')));
    });

    test('accuracy boundary: exactly at threshold is accepted', () async {
      final boundaryFix = _makeLocation(id: 'boundary', accuracy: accuracyThreshold);

      if (boundaryFix.accuracy <= accuracyThreshold) {
        await datasource.saveLocation(boundaryFix, tripId);
      }

      final pending =
          await datasource.getPendingLocations(tripId: tripId, limit: 10);
      expect(pending.length, 1,
          reason: 'Fix exactly at threshold (50m == 50m) must be accepted');
    });

    test('DriverLocation.isAccurate helper aligns with 50m default threshold',
        () {
      expect(_makeLocation(id: 'a', accuracy: 49.9).isAccurate, isTrue);
      expect(_makeLocation(id: 'b', accuracy: 50.0).isAccurate, isTrue);
      expect(_makeLocation(id: 'c', accuracy: 50.1).isAccurate, isFalse);
    });
  });
}
