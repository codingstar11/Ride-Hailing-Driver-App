import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import '../../../../core/network/connectivity_service.dart';
import '../../../../core/services/upload_worker.dart';
import '../../../../core/utils/app_logger.dart';
import '../../domain/repositories/location_repository.dart';
import '../../domain/usecases/start_tracking_usecase.dart';
import '../../domain/usecases/stop_tracking_usecase.dart';
import '../../domain/usecases/upload_pending_locations_usecase.dart';
import 'location_state.dart';

export 'location_state.dart';

class LocationBloc extends Bloc<LocationEvent, LocationState> {
  final StartTrackingUseCase _startTracking;
  final StopTrackingUseCase _stopTracking;
  final UploadPendingLocationsUseCase _uploadPending;
  final ConnectivityService _connectivityService;
  final LocationRepository _locationRepository;

  StreamSubscription? _pendingCountSub;
  StreamSubscription? _connectivitySub;
  UploadWorker? _uploadWorker;

  LocationBloc({
    required StartTrackingUseCase startTracking,
    required StopTrackingUseCase stopTracking,
    required UploadPendingLocationsUseCase uploadPending,
    required ConnectivityService connectivityService,
    required LocationRepository locationRepository,
  })  : _startTracking = startTracking,
        _stopTracking = stopTracking,
        _uploadPending = uploadPending,
        _connectivityService = connectivityService,
        _locationRepository = locationRepository,
        super(const LocationInitial()) {
    // droppable: if a start is already in progress, drop the duplicate.
    on<LocationTrackingStarted>(_onTrackingStarted, transformer: droppable());
    on<TripRestorationRequested>(_onTripRestorationRequested);
    on<LocationTrackingStopped>(_onTrackingStopped);
    on<LocationUpdated>(_onLocationUpdated);
    on<LocationUploadRequested>(_onUploadRequested);
    on<LocationPendingCountUpdated>(_onPendingCountUpdated);

    _connectivitySub = _connectivityService.onConnectivityChanged.listen(
      (isConnected) {
        if (isConnected) {
          AppLogger.networkRestored();
        } else {
          AppLogger.networkDisconnected();
        }
      },
    );
  }

  // ── Trip restoration on app relaunch ─────────────────────────────────────

  Future<void> _onTripRestorationRequested(
    TripRestorationRequested event,
    Emitter<LocationState> emit,
  ) async {
    try {
      AppLogger.info('BLOC', 'Checking for persisted active trip…');
      final tripId = await _locationRepository.getActiveTripId();

      if (tripId == null) {
        AppLogger.info('BLOC', 'No active trip found — staying at initial state');
        return;
      }

      AppLogger.info('BLOC', 'Active trip found — restoring  trip=$tripId');
      emit(LocationPermissionChecking(tripId: tripId));

      await _locationRepository.resumeTracking(tripId);

      emit(LocationTracking(tripId: tripId));
      _pendingCountSub = _uploadPending.pendingCount.listen(
        (count) => add(LocationPendingCountUpdated(count)),
      );

      _startUploadWorker();

      AppLogger.info('BLOC', 'Trip restored successfully  trip=$tripId');
    } catch (e) {
      AppLogger.error('BLOC', 'Failed to restore active trip', e);
      emit(const LocationInitial());
    }
  }

  Future<void> _onTrackingStarted(
    LocationTrackingStarted event,
    Emitter<LocationState> emit,
  ) async {
    try {
      AppLogger.info('BLOC',
          'LocationTrackingStarted event received  trip=${event.tripId}');

      // Guard: if we are already tracking, ignore the duplicate start.
      if (state is LocationTracking) return;

      emit(LocationPermissionChecking(tripId: event.tripId));

      final result = await _startTracking(event.tripId);

      switch (result) {
        case TrackingStartResult.started:
          emit(LocationTracking(tripId: event.tripId));
          _pendingCountSub = _uploadPending.pendingCount.listen(
            (count) => add(LocationPendingCountUpdated(count)),
          );
          _startUploadWorker();

        case TrackingStartResult.locationServicesDisabled:
          AppLogger.warn('BLOC', 'Cannot start — location services disabled');
          emit(const LocationPermissionError(
            message:
                'Location services are disabled. Please enable GPS in your device settings.',
            type: PermissionErrorType.serviceDisabled,
          ));

        case TrackingStartResult.permissionDenied:
          AppLogger.warn('BLOC', 'Cannot start — permission denied');
          emit(const LocationPermissionError(
            message: 'Location permission is required to track your trip.',
            type: PermissionErrorType.denied,
          ));

        case TrackingStartResult.permissionPermanentlyDenied:
          AppLogger.warn('BLOC', 'Cannot start — permission permanently denied');
          emit(const LocationPermissionError(
            message:
                'Location permission was permanently denied. Please enable it in app Settings.',
            type: PermissionErrorType.permanentlyDenied,
          ));

        case TrackingStartResult.backgroundPermissionMissing:
          AppLogger.warn('BLOC', 'Cannot start — background permission missing');
          emit(const LocationPermissionError(
            message:
                'Background location ("Allow All The Time") is required so tracking '
                'continues when your screen is locked. Please update location '
                'permission to "Always" in app Settings.',
            type: PermissionErrorType.backgroundRequired,
          ));
      }
    } catch (e) {
      AppLogger.error('BLOC', 'Unexpected error starting tracking', e);
      emit(LocationError(e.toString()));
    }
  }

  Future<void> _onTrackingStopped(
    LocationTrackingStopped event,
    Emitter<LocationState> emit,
  ) async {
    final tripId = state is LocationTracking
        ? (state as LocationTracking).tripId
        : 'unknown';

    _stopUploadWorker();
    await _pendingCountSub?.cancel();
    _pendingCountSub = null;
    await _stopTracking();

    final remaining = await _uploadPending.pendingCount.first;
    AppLogger.tripStopped(tripId, totalPoints: 0);
    emit(LocationStopped(remainingPending: remaining));
  }

  void _onLocationUpdated(
    LocationUpdated event,
    Emitter<LocationState> emit,
  ) {
    if (state is LocationTracking) {
      final current = state as LocationTracking;
      AppLogger.locationEmittedToUi(
        event.location.latitude,
        event.location.longitude,
      );
      emit(current.copyWith(currentLocation: event.location));
    }
  }

  Future<void> _onUploadRequested(
    LocationUploadRequested event,
    Emitter<LocationState> emit,
  ) async {
    if (state is LocationTracking) {
      final current = state as LocationTracking;
      AppLogger.info('BLOC', 'Manual upload requested');
      emit(current.copyWith(isUploading: true));
      await _uploadPending();
      emit(current.copyWith(isUploading: false));
    }
  }

  void _onPendingCountUpdated(
    LocationPendingCountUpdated event,
    Emitter<LocationState> emit,
  ) {
    if (state is LocationTracking) {
      final current = state as LocationTracking;
      emit(current.copyWith(pendingCount: event.count));
    }
  }

  // ── Upload worker lifecycle ───────────────────────────────────────────────

  void _startUploadWorker() {
    _uploadWorker?.stop();
    _uploadWorker = UploadWorker(_locationRepository, _connectivityService);
    _uploadWorker!.start();
  }

  void _stopUploadWorker() {
    _uploadWorker?.stop();
    _uploadWorker = null;
  }

  @override
  Future<void> close() {
    _stopUploadWorker();
    _pendingCountSub?.cancel();
    _connectivitySub?.cancel();
    return super.close();
  }
}
