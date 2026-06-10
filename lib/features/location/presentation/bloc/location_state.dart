import 'package:equatable/equatable.dart';
import '../../domain/entities/driver_location.dart';

// ── Events ───────────────────────────────────────────────────────────────────

abstract class LocationEvent extends Equatable {
  const LocationEvent();
  @override
  List<Object?> get props => [];
}

class LocationTrackingStarted extends LocationEvent {
  final String tripId;
  const LocationTrackingStarted(this.tripId);
  @override
  List<Object?> get props => [tripId];
}

/// Fired once on app startup to check whether a trip was active before the
/// app was killed. If so the bloc resumes tracking without asking the driver
/// to press "Start Trip" again.
class TripRestorationRequested extends LocationEvent {
  const TripRestorationRequested();
}

class LocationTrackingStopped extends LocationEvent {
  const LocationTrackingStopped();
}

class LocationUpdated extends LocationEvent {
  final DriverLocation location;
  const LocationUpdated(this.location);
  @override
  List<Object?> get props => [location];
}

class LocationUploadRequested extends LocationEvent {
  const LocationUploadRequested();
}

class LocationPendingCountUpdated extends LocationEvent {
  final int count;
  const LocationPendingCountUpdated(this.count);
  @override
  List<Object?> get props => [count];
}

// ── Permission error type ────────────────────────────────────────────────────

enum PermissionErrorType {
  /// GPS turned off at device level.
  serviceDisabled,

  /// User denied `location` permission.
  denied,

  /// User permanently denied — must go to Settings.
  permanentlyDenied,

  /// Foreground granted but background ("Always") is missing.
  backgroundRequired,
}

// ── States ───────────────────────────────────────────────────────────────────

abstract class LocationState extends Equatable {
  const LocationState();
  @override
  List<Object?> get props => [];
}

class LocationInitial extends LocationState {
  const LocationInitial();
}

/// Emitted while the permission request dialog is in flight.
class LocationPermissionChecking extends LocationState {
  final String tripId;
  const LocationPermissionChecking({required this.tripId});
  @override
  List<Object?> get props => [tripId];
}

/// Emitted when a required permission is missing or denied.
/// The UI shows an appropriate dialog based on [type].
class LocationPermissionError extends LocationState {
  final String message;
  final PermissionErrorType type;
  const LocationPermissionError({required this.message, required this.type});
  @override
  List<Object?> get props => [message, type];
}

class LocationTracking extends LocationState {
  final DriverLocation? currentLocation;
  final int pendingCount;
  final bool isUploading;
  final String tripId;

  const LocationTracking({
    required this.tripId,
    this.currentLocation,
    this.pendingCount = 0,
    this.isUploading = false,
  });

  LocationTracking copyWith({
    DriverLocation? currentLocation,
    int? pendingCount,
    bool? isUploading,
  }) {
    return LocationTracking(
      tripId: tripId,
      currentLocation: currentLocation ?? this.currentLocation,
      pendingCount: pendingCount ?? this.pendingCount,
      isUploading: isUploading ?? this.isUploading,
    );
  }

  @override
  List<Object?> get props => [tripId, currentLocation, pendingCount, isUploading];
}

class LocationStopped extends LocationState {
  final int remainingPending;
  const LocationStopped({this.remainingPending = 0});
  @override
  List<Object?> get props => [remainingPending];
}

class LocationError extends LocationState {
  final String message;
  const LocationError(this.message);
  @override
  List<Object?> get props => [message];
}
