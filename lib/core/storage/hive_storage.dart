import 'package:hive_flutter/hive_flutter.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';

import 'location_entry.dart';
import 'telemetry_entry.dart';

class HiveStorage {
  static final _logger = Logger();

  static const String locationQueueBox = 'location_queue';
  static const String activeTripBox = 'active_trip';
  static const String completedTripsBox = 'completed_trips';
  static const String configBox = 'config';
  static const String telemetryBox = 'telemetry';

  static bool _initialised = false;

  static Future<void> initialise() async {
    if (_initialised) return;

    final dir = await getApplicationDocumentsDirectory();
    await Hive.initFlutter(dir.path);

    // Register hand-written TypeAdapters.
    if (!Hive.isAdapterRegistered(LocationEntryAdapter.adapterTypeId)) {
      Hive.registerAdapter(LocationEntryAdapter());
    }
    if (!Hive.isAdapterRegistered(TelemetryEntryAdapter.adapterTypeId)) {
      Hive.registerAdapter(TelemetryEntryAdapter());
    }

    // Open boxes eagerly at startup so they are available synchronously later.
    await Hive.openLazyBox<LocationEntry>(locationQueueBox);
    await Hive.openBox<Map>(activeTripBox);
    await Hive.openLazyBox<Map>(completedTripsBox);
    await Hive.openBox<dynamic>(configBox);
    await Hive.openLazyBox<TelemetryEntry>(telemetryBox);

    _initialised = true;
    _logger.i('[HiveStorage] All boxes opened successfully');
  }

  // ── Box accessors ────────────────────────────────────────────────────────

  static LazyBox<LocationEntry> get locationQueue =>
      Hive.lazyBox<LocationEntry>(locationQueueBox);

  static Box<Map> get activeTrip => Hive.box<Map>(activeTripBox);

  static LazyBox<Map> get completedTrips =>
      Hive.lazyBox<Map>(completedTripsBox);

  static Box<dynamic> get config => Hive.box<dynamic>(configBox);

  static LazyBox<TelemetryEntry> get telemetry =>
      Hive.lazyBox<TelemetryEntry>(telemetryBox);

  /// Closes all boxes gracefully — call from AppLifecycleState.detached.
  static Future<void> close() async {
    await Hive.close();
    _initialised = false;
    _logger.i('[HiveStorage] All boxes closed');
  }

  /// Whether initialise() has already been called. Useful in tests.
  static bool get isInitialised => _initialised;
}
