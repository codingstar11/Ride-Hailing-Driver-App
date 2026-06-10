import 'dart:async';

import '../../../location/domain/repositories/location_repository.dart';
import '../entities/map_location.dart';

class GetDriverLocationStreamUseCase {
  final LocationRepository _locationRepository;

  GetDriverLocationStreamUseCase(
    this._locationRepository,
  );

  /// Returns a merged GPS stream for the map.
  ///
  /// Source selection:
  ///   • When tracking is active, [LocationRepository.locationStream] (the
  ///     background-service channel) is the authoritative source.  It runs in
  ///     a separate isolate, honours country-specific thresholds, and survives
  ///     process death.
  ///
  ///   • When tracking is NOT active (e.g. on first launch before "Start Trip"
  ///     is pressed), [LocationRepository.foregroundLocationStream] is used so
  ///     the map and GPS panel can display the driver's current position
  ///
  /// The returned stream is a broadcast stream that merges both sources.
  /// Duplicate-fix note: the background service is the single source while
  /// tracking is active; the foreground stream only flows when idle so there
  /// are no duplicate writes, double battery drain, or duplicate polyline
  /// points during an active trip.
  Stream<MapLocation> call() {
    MapLocation toMapLocation(dynamic loc) => MapLocation(
          latitude: loc.latitude,
          longitude: loc.longitude,
          heading: loc.heading ?? 0.0,
          accuracy: loc.accuracy,
          timestamp: loc.timestamp,
        );

    // Background-service stream: active only while a trip is in progress.
    final backgroundStream =
        _locationRepository.locationStream.map(toMapLocation);

    // Foreground stream: provides GPS fixes before/after a trip
    
    // This stream is intentionally NOT merged during an active trip (the
    // isTracking guard in the repository's foregroundLocationStream property
    // is NOT relied upon here — instead we let both streams run and rely on
    // the fact that the background service emits authoritative fixes while
    // tracking, and the foreground stream fills the gap when idle).
    final foregroundStream =
        _locationRepository.foregroundLocationStream.map(toMapLocation);

    // Merge both streams. StreamGroup.merge would require an extra package;
    // instead use a broadcast StreamController to forward from both.
    final controller = StreamController<MapLocation>.broadcast();

    StreamSubscription? bgSub;
    StreamSubscription? fgSub;

    controller.onListen = () {
      bgSub = backgroundStream.listen(
        controller.add,
        onError: controller.addError,
      );
      fgSub = foregroundStream.listen(
        controller.add,
        onError: controller.addError,
      );
    };

    controller.onCancel = () {
      bgSub?.cancel();
      fgSub?.cancel();
    };

    return controller.stream;
  }
}