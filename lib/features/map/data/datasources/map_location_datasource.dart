import 'dart:async';
import 'dart:math';
import 'package:logger/logger.dart';
import 'package:ride_hailing_driver/core/constants/app_constants.dart';

import '../../../../core/utils/app_logger.dart';
import '../../domain/entities/map_location.dart';

/// Simulates real-time location updates from the backend (WebSocket / polling).
///
/// In production this would listen to a WebSocket stream or poll a REST endpoint.
/// The simulated positions are used for the map animation. The real driver location (from GPS via BackgroundService) is emitted
/// separately through the LocationRepository → LocationBloc → MapBloc pipeline.
class MapLocationDatasource {
  StreamController<MapLocation>? _controller;

  double _lat = AppConstants.initialLatitude;
  double _lng = AppConstants.initialLongitude;
  double _heading = 45.0;
  final _random = Random();
  int _emitCount = 0;
  Timer? _timer;

  Stream<MapLocation> getDriverLocationStream() {
    _controller?.close();
    _timer?.cancel();

    _controller = StreamController<MapLocation>.broadcast();
    _emitCount = 0;

    AppLogger.info('MAP_DS', 'Starting simulated location stream  '
        'origin=(${ _lat.toStringAsFixed(4)}, ${_lng.toStringAsFixed(4)})  '
        'interval=5s');

    // Emit the initial position immediately.
    _emitLocation();

    // Then emit every 5 seconds.
    _timer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (_controller?.isClosed ?? true) {
        timer.cancel();
        AppLogger.info('MAP_DS', 'Stream closed — timer cancelled');
        return;
      }
      _emitLocation();
    });

    return _controller!.stream;
  }

  void _emitLocation() {
    // Simulate smooth movement: small deltas in both axes.
    final deltaLat = (_random.nextDouble() - 0.5) * 0.0008;
    final deltaLng = (_random.nextDouble() - 0.5) * 0.0008;
    _lat += deltaLat;
    _lng += deltaLng;

    // Smooth heading drift.
    _heading = (_heading + (_random.nextDouble() - 0.5) * 20) % 360;
    final accuracy = 8.0 + _random.nextDouble() * 12;
    _emitCount++;

    final location = MapLocation(
      latitude: _lat,
      longitude: _lng,
      heading: _heading,
      accuracy: accuracy,
      timestamp: DateTime.now(),
    );

    _controller?.add(location);

    AppLogger.debug('MAP_DS',
        'Simulated location #$_emitCount emitted  '
        'lat=${_lat.toStringAsFixed(6)}  '
        'lng=${_lng.toStringAsFixed(6)}  '
        'heading=${_heading.toStringAsFixed(1)}°  '
        'acc=${accuracy.toStringAsFixed(1)}m');
  }

  void dispose() {
    _timer?.cancel();
    _controller?.close();
    _controller = null;
    AppLogger.info('MAP_DS', 'Datasource disposed');
  }
}
