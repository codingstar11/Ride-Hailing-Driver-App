import 'dart:async';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../../core/utils/app_logger.dart';
import '../../domain/entities/map_location.dart';
import '../../domain/usecases/get_driver_location_stream_usecase.dart';

// ── Events ────────────────────────────────────────────────────────────────────

abstract class MapEvent extends Equatable {
  const MapEvent();
  @override
  List<Object?> get props => [];
}

class MapInitialized extends MapEvent {
  const MapInitialized();
}

class MapLocationReceived extends MapEvent {
  final MapLocation location;
  const MapLocationReceived(this.location);
  @override
  List<Object?> get props => [location];
}

class MapControllerReady extends MapEvent {
  final GoogleMapController controller;
  const MapControllerReady(this.controller);
  @override
  List<Object?> get props => [controller];
}

/// Fired when the BLoC should move camera to the current location
/// (e.g. after trip restoration, or when controller becomes available
/// after a location was already received).
class MapCameraSnapRequested extends MapEvent {
  const MapCameraSnapRequested();
}

/// Fired when tracking starts/resumes so MapBloc re-subscribes to the
/// merged (background + foreground) location stream.
class MapTrackingStarted extends MapEvent {
  const MapTrackingStarted();
}

class _MapAnimationTick extends MapEvent {
  final double progress;
  const _MapAnimationTick(this.progress);
  @override
  List<Object?> get props => [progress];
}

// ── States ────────────────────────────────────────────────────────────────────

abstract class MapState extends Equatable {
  const MapState();
  @override
  List<Object?> get props => [];
}

class MapInitial extends MapState {
  const MapInitial();
}

class MapLoaded extends MapState {
  final MapLocation? currentLocation;
  final MapLocation? previousLocation;
  final List<LatLng> routePoints;
  final GoogleMapController? mapController;

  /// 0.0 → 1.0 drives the smooth marker lerp between GPS fixes.
  final double animationProgress;

  const MapLoaded({
    this.currentLocation,
    this.previousLocation,
    this.routePoints = const [],
    this.mapController,
    this.animationProgress = 1.0,
  });

  /// Linearly interpolated position for smooth marker rendering.
  LatLng? get interpolatedPosition {
    if (currentLocation == null) return null;
    if (previousLocation == null || animationProgress >= 1.0) {
      return currentLocation!.latLng;
    }
    final lat = _lerp(
      previousLocation!.latitude,
      currentLocation!.latitude,
      animationProgress,
    );
    final lng = _lerp(
      previousLocation!.longitude,
      currentLocation!.longitude,
      animationProgress,
    );
    return LatLng(lat, lng);
  }

  double _lerp(double a, double b, double t) => a + (b - a) * t;

  MapLoaded copyWith({
    MapLocation? currentLocation,
    MapLocation? previousLocation,
    List<LatLng>? routePoints,
    GoogleMapController? mapController,
    double? animationProgress,
  }) {
    return MapLoaded(
      currentLocation: currentLocation ?? this.currentLocation,
      previousLocation: previousLocation ?? this.previousLocation,
      routePoints: routePoints ?? this.routePoints,
      mapController: mapController ?? this.mapController,
      animationProgress: animationProgress ?? this.animationProgress,
    );
  }

  @override
  List<Object?> get props => [
        currentLocation,
        previousLocation,
        routePoints,
        animationProgress,
      ];
}

// ── BLoC ──────────────────────────────────────────────────────────────────────

class MapBloc extends Bloc<MapEvent, MapState> {
  final GetDriverLocationStreamUseCase _getLocationStream;
  StreamSubscription? _locationSub;
  Timer? _animationTimer;
  bool _firstLocationReceived = false;
  int _locationCount = 0;

  /// Full canonical route history — never trimmed so long trips are preserved.
  /// At 1 point/5 s a 10-hour trip produces ~7 200 points (~576 KB of LatLng
  /// structs), which is well within mobile memory budgets.
  final List<LatLng> _fullRouteHistory = [];

  /// Maximum points passed to the map widget for rendering.
  /// Google Maps renders polylines efficiently up to a few thousand nodes;
  /// beyond that we decimate while keeping the most recent segment sharp.
  static const int _maxRenderPoints = 200;

  /// Holds the first location received before the controller was ready,
  /// so we can snap the camera once onMapCreated fires.
  MapLocation? _pendingCameraLocation;

  static const _animationDuration = Duration(milliseconds: 4500);
  static const _animationSteps = 60;

  MapBloc(this._getLocationStream) : super(const MapInitial()) {
    on<MapInitialized>(_onInitialized);
    on<MapLocationReceived>(_onLocationReceived);
    on<MapControllerReady>(_onMapControllerReady);
    on<MapCameraSnapRequested>(_onCameraSnapRequested);
    on<MapTrackingStarted>(_onTrackingStarted);
    on<_MapAnimationTick>(_onAnimationTick);
  }

  void _onInitialized(MapInitialized event, Emitter<MapState> emit) {
    AppLogger.info(
        'MAP_BLOC', 'Map initialized — subscribing to location stream');
    emit(const MapLoaded());
    _subscribeToLocationStream();
  }

  /// Called when tracking starts or resumes. Re-subscribes to the merged
  /// stream so the foreground stream (gated on isTracking) is now included.
  void _onTrackingStarted(MapTrackingStarted event, Emitter<MapState> emit) {
    AppLogger.info(
        'MAP_BLOC', 'Tracking started — re-subscribing to location stream');
    _firstLocationReceived = false;
    // _fullRouteHistory.clear();
    _subscribeToLocationStream();
  }

  void _subscribeToLocationStream() {
    _locationSub?.cancel();
    _locationSub = _getLocationStream().listen(
      (location) {
        AppLogger.debug(
          'MAP_BLOC',
          'Location received from stream  '
              'lat=${location.latitude.toStringAsFixed(6)}  '
              'lng=${location.longitude.toStringAsFixed(6)}  '
              'heading=${location.heading.toStringAsFixed(1)}°',
        );
        add(MapLocationReceived(location));
      },
      onError: (Object e) {
        AppLogger.error('MAP_BLOC', 'Location stream error', e);
      },
    );
  }

  void _onLocationReceived(
    MapLocationReceived event,
    Emitter<MapState> emit,
  ) {
    final current = state is MapLoaded ? state as MapLoaded : const MapLoaded();
    final previous = current.currentLocation;
    _locationCount++;

    final isFirstFix = !_firstLocationReceived;
    _firstLocationReceived = true;

    // Append to the full canonical history (never trimmed).
    _fullRouteHistory.add(event.location.latLng);

    // Build a render-safe list: keep all points if under threshold, otherwise
    // decimate the older segment while preserving the recent 200 points sharp.
    final renderPoints = _buildRenderRoute(_fullRouteHistory);

    emit(current.copyWith(
      currentLocation: event.location,
      previousLocation: previous,
      routePoints: renderPoints,
      animationProgress: 0.0,
    ));

    // Camera follow: move to driver on every GPS update.
    final controller = current.mapController;
    if (controller != null) {
      final target = event.location.latLng;
      if (isFirstFix) {
        AppLogger.info(
          'MAP_BLOC',
          '🗺  First real GPS fix — moving camera to actual location  '
              'lat=${target.latitude.toStringAsFixed(6)}  '
              'lng=${target.longitude.toStringAsFixed(6)}',
        );
        controller.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(target: target, zoom: 16),
          ),
        );
      } else {
        controller.animateCamera(CameraUpdate.newLatLng(target));
      }
    } else {
      // Controller not ready yet — stash so we snap when it arrives.
      _pendingCameraLocation = event.location;
      AppLogger.debug(
          'MAP_BLOC', 'Controller not ready — storing pending camera location');
    }

    // Start smooth lerp animation for marker movement.
    _animationTimer?.cancel();
    int step = 0;
    _animationTimer = Timer.periodic(
      Duration(
          milliseconds: _animationDuration.inMilliseconds ~/ _animationSteps),
      (timer) {
        step++;
        final progress = (step / _animationSteps).clamp(0.0, 1.0);
        add(_MapAnimationTick(progress));
        if (progress >= 1.0) timer.cancel();
      },
    );
  }

  void _onAnimationTick(_MapAnimationTick event, Emitter<MapState> emit) {
    if (state is MapLoaded) {
      emit((state as MapLoaded).copyWith(animationProgress: event.progress));
    }
  }

  void _onMapControllerReady(
    MapControllerReady event,
    Emitter<MapState> emit,
  ) {
    AppLogger.info('MAP_BLOC', 'GoogleMap controller ready');
    if (state is MapLoaded) {
      emit((state as MapLoaded).copyWith(mapController: event.controller));
    }

    // If we already have a location but the controller just arrived,
    // snap to that location immediately.
    final pending = _pendingCameraLocation;
    if (pending != null) {
      AppLogger.info(
        'MAP_BLOC',
        '📷 Controller ready with pending location — snapping camera  '
            'lat=${pending.latitude.toStringAsFixed(6)}',
      );
      event.controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: pending.latLng, zoom: 16),
        ),
      );
      _pendingCameraLocation = null;
    }
  }

  void _onCameraSnapRequested(
    MapCameraSnapRequested event,
    Emitter<MapState> emit,
  ) {
    if (state is! MapLoaded) return;
    final loaded = state as MapLoaded;
    if (loaded.mapController == null || loaded.currentLocation == null) return;
    final target = loaded.currentLocation!.latLng;
    AppLogger.info('MAP_BLOC', '📷 Camera snap requested — moving to driver');
    loaded.mapController!.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: target, zoom: 16),
      ),
    );
  }

  /// Builds the list of [LatLng] points passed to the map widget.
  ///
  /// Returns all points when under [_maxRenderPoints]. Once the history
  /// exceeds that threshold, only the most recent [_maxRenderPoints] points
  /// are returned so the live portion of the route stays sharp and memory
  /// usage stays bounded.
  List<LatLng> _buildRenderRoute(List<LatLng> full) {
    if (full.length <= _maxRenderPoints) return List.unmodifiable(full);
    return List.unmodifiable(full.sublist(full.length - _maxRenderPoints));
  }

  @override
  Future<void> close() {
    AppLogger.info(
        'MAP_BLOC', 'MapBloc closed  totalLocationsReceived=$_locationCount');
    _locationSub?.cancel();
    _animationTimer?.cancel();
    return super.close();
  }
}