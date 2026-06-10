import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';

import 'package:ride_hailing_driver/features/location/domain/usecases/start_tracking_usecase.dart';
import 'package:ride_hailing_driver/features/location/domain/usecases/stop_tracking_usecase.dart';
import 'package:ride_hailing_driver/features/location/domain/usecases/upload_pending_locations_usecase.dart';
import 'package:ride_hailing_driver/features/location/domain/repositories/location_repository.dart';
import 'package:ride_hailing_driver/features/location/presentation/bloc/location_bloc.dart';
import 'package:ride_hailing_driver/core/network/connectivity_service.dart';

import 'location_bloc_test.mocks.dart';

@GenerateMocks([
  StartTrackingUseCase,
  StopTrackingUseCase,
  UploadPendingLocationsUseCase,
  ConnectivityService,
  LocationRepository,
])
void main() {
  late MockStartTrackingUseCase mockStart;
  late MockStopTrackingUseCase mockStop;
  late MockUploadPendingLocationsUseCase mockUpload;
  late MockConnectivityService mockConnectivity;
  late MockLocationRepository mockLocationRepository;

  setUp(() {
    mockStart = MockStartTrackingUseCase();
    mockStop = MockStopTrackingUseCase();
    mockUpload = MockUploadPendingLocationsUseCase();
    mockConnectivity = MockConnectivityService();
    mockLocationRepository = MockLocationRepository();

    when(mockUpload.pendingCount).thenAnswer((_) => Stream.value(0));
    when(mockConnectivity.onConnectivityChanged)
        .thenAnswer((_) => const Stream.empty());
    when(mockLocationRepository.getActiveTripId())
        .thenAnswer((_) async => null);
    when(mockLocationRepository.pendingLocationCount)
        .thenAnswer((_) => Stream.value(0));
    when(mockLocationRepository.uploadPendingLocations())
        .thenAnswer((_) async => 0);
    when(mockConnectivity.isConnected).thenReturn(false);
  });

  LocationBloc _buildBloc() => LocationBloc(
        startTracking: mockStart,
        stopTracking: mockStop,
        uploadPending: mockUpload,
        connectivityService: mockConnectivity,
        locationRepository: mockLocationRepository,
      );

  group('LocationBloc', () {
    // ── Start tracking ─────────────────────────────────────────────────

    blocTest<LocationBloc, LocationState>(
      'emits [LocationPermissionChecking, LocationTracking] when tracking starts successfully',
      build: () {
        when(mockStart.call(any))
            .thenAnswer((_) async => TrackingStartResult.started);
        return _buildBloc();
      },
      act: (bloc) => bloc.add(const LocationTrackingStarted('TRIP_001')),
      expect: () => [
        isA<LocationPermissionChecking>(),
        isA<LocationTracking>().having((s) => s.tripId, 'tripId', 'TRIP_001'),
      ],
      verify: (_) {
        verify(mockStart.call('TRIP_001')).called(1);
      },
    );

    blocTest<LocationBloc, LocationState>(
      'emits LocationPermissionError(serviceDisabled) when GPS off',
      build: () {
        when(mockStart.call(any)).thenAnswer(
            (_) async => TrackingStartResult.locationServicesDisabled);
        return _buildBloc();
      },
      act: (bloc) => bloc.add(const LocationTrackingStarted('TRIP_001')),
      expect: () => [
        isA<LocationPermissionChecking>(),
        isA<LocationPermissionError>().having(
          (s) => s.type,
          'type',
          PermissionErrorType.serviceDisabled,
        ),
      ],
    );

    blocTest<LocationBloc, LocationState>(
      'emits LocationPermissionError(denied) when permission denied',
      build: () {
        when(mockStart.call(any))
            .thenAnswer((_) async => TrackingStartResult.permissionDenied);
        return _buildBloc();
      },
      act: (bloc) => bloc.add(const LocationTrackingStarted('TRIP_001')),
      expect: () => [
        isA<LocationPermissionChecking>(),
        isA<LocationPermissionError>().having(
          (s) => s.type,
          'type',
          PermissionErrorType.denied,
        ),
      ],
    );

    blocTest<LocationBloc, LocationState>(
      'emits LocationError when startTracking throws',
      build: () {
        when(mockStart.call(any)).thenThrow(Exception('Permission denied'));
        return _buildBloc();
      },
      act: (bloc) => bloc.add(const LocationTrackingStarted('TRIP_001')),
      expect: () => [
        isA<LocationPermissionChecking>(),
        isA<LocationError>().having(
          (s) => s.message,
          'message',
          contains('Permission denied'),
        ),
      ],
    );

    // ── Stop tracking ──────────────────────────────────────────────────

    blocTest<LocationBloc, LocationState>(
      'emits LocationStopped when tracking stops',
      build: () {
        when(mockStop.call()).thenAnswer((_) async {});
        when(mockUpload.pendingCount).thenAnswer((_) => Stream.value(0));
        return _buildBloc();
      },
      seed: () => const LocationTracking(tripId: 'TRIP_001'),
      act: (bloc) => bloc.add(const LocationTrackingStopped()),
      expect: () => [isA<LocationStopped>()],
      verify: (_) {
        verify(mockStop.call()).called(1);
      },
    );

    blocTest<LocationBloc, LocationState>(
      'LocationStopped includes remaining pending count',
      build: () {
        when(mockStop.call()).thenAnswer((_) async {});
        when(mockUpload.pendingCount).thenAnswer((_) => Stream.value(3));
        return _buildBloc();
      },
      seed: () => const LocationTracking(tripId: 'TRIP_001'),
      act: (bloc) => bloc.add(const LocationTrackingStopped()),
      expect: () => [
        isA<LocationStopped>().having(
          (s) => s.remainingPending,
          'remainingPending',
          3,
        ),
      ],
    );

    // ── Pending count updates ──────────────────────────────────────────

    blocTest<LocationBloc, LocationState>(
      'pending count updates propagate to LocationTracking state',
      build: () {
        when(mockStart.call(any))
            .thenAnswer((_) async => TrackingStartResult.started);
        when(mockUpload.pendingCount)
            .thenAnswer((_) => Stream.fromIterable([0, 5, 10, 0]));
        return _buildBloc();
      },
      act: (bloc) async {
        bloc.add(const LocationTrackingStarted('TRIP_001'));
        await Future.delayed(const Duration(milliseconds: 100));
      },
      expect: () => [
        isA<LocationPermissionChecking>(),
        isA<LocationTracking>().having((s) => s.pendingCount, 'count', 0),
        // The stream's first emission (0) is deduplicated by BLoC because
        // the state is already LocationTracking(count:0). Next distinct values:
        isA<LocationTracking>().having((s) => s.pendingCount, 'count', 5),
        isA<LocationTracking>().having((s) => s.pendingCount, 'count', 10),
        isA<LocationTracking>().having((s) => s.pendingCount, 'count', 0),
      ],
    );

    // ── Upload requested ───────────────────────────────────────────────

    blocTest<LocationBloc, LocationState>(
      'upload requested sets isUploading flag then clears it',
      build: () {
        when(mockUpload.call()).thenAnswer((_) async => 5);
        return _buildBloc();
      },
      seed: () => const LocationTracking(tripId: 'TRIP_001'),
      act: (bloc) => bloc.add(const LocationUploadRequested()),
      expect: () => [
        isA<LocationTracking>()
            .having((s) => s.isUploading, 'isUploading', true),
        isA<LocationTracking>()
            .having((s) => s.isUploading, 'isUploading', false),
      ],
    );

    // ── Trip restoration ───────────────────────────────────────────────

    blocTest<LocationBloc, LocationState>(
      'TripRestorationRequested stays at LocationInitial when no active trip',
      build: () {
        when(mockLocationRepository.getActiveTripId())
            .thenAnswer((_) async => null);
        return _buildBloc();
      },
      act: (bloc) => bloc.add(const TripRestorationRequested()),
      expect: () => [],
    );

    blocTest<LocationBloc, LocationState>(
      'TripRestorationRequested emits LocationTracking when trip exists',
      build: () {
        when(mockLocationRepository.getActiveTripId())
            .thenAnswer((_) async => 'TRIP_RESTORE');
        when(mockLocationRepository.resumeTracking(any))
            .thenAnswer((_) async {});
        return _buildBloc();
      },
      act: (bloc) => bloc.add(const TripRestorationRequested()),
      expect: () => [
        isA<LocationPermissionChecking>(),
        isA<LocationTracking>()
            .having((s) => s.tripId, 'tripId', 'TRIP_RESTORE'),
      ],
    );

    // ── Duplicate start guard ──────────────────────────────────────────

    test('starting twice does not call startTracking use-case twice', () async {
      when(mockStart.call(any))
          .thenAnswer((_) async => TrackingStartResult.started);
      final bloc = _buildBloc();

      bloc.add(const LocationTrackingStarted('TRIP_001'));
      bloc.add(const LocationTrackingStarted('TRIP_001'));
      await Future.delayed(const Duration(milliseconds: 100));

      verify(mockStart.call('TRIP_001')).called(1);
      await bloc.close();
    });
  });
}
