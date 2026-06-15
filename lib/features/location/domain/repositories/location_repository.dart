import '../entities/driver_location.dart';

abstract class LocationRepository {
  /// Start background location tracking
  Future<void> startTracking(String tripId);

  /// Resume a trip that was already active before the app was killed/closed.
  /// Unlike [startTracking] this does not report a new trip-start to the
  /// server and re-uses the existing persisted trip state.
  Future<void> resumeTracking(String tripId);

  /// Stop background location tracking
  Future<void> stopTracking();

  /// Save a location to local queue
  Future<void> saveLocationLocally(DriverLocation location);

  /// Upload all pending locations to server
  /// Returns number of successfully uploaded locations
  Future<int> uploadPendingLocations();

  /// Stream of pending location count
  Stream<int> get pendingLocationCount;

  /// Check how many locations are pending upload
  Future<int> getPendingCount();

  /// Returns the persisted active trip ID from Hive, or null if no trip is active.
  Future<String?> getActiveTripId();

  /// Request and verify location permissions
  Future<bool> requestPermissions();

  /// Whether tracking is currently active
  bool get isTracking;

  /// Set the ISO country code used when loading CountryConfig on the next
  /// tracking start. Must be called whenever the driver profile is loaded.
  void setCountryCode(String code);

  /// Live stream of location updates from background service
  Stream<DriverLocation> get locationStream;

  /// Live stream of location updates from foreground GPS (used before trip starts)
  Stream<DriverLocation> get foregroundLocationStream;

  /// Shared entry point for processing a raw background location event.
  /// Used by both the standard stream listener and the headless runner task,
  /// ensuring identical save/upload logic regardless of how the event arrived.
  Future<void> handleBackgroundLocationEvent(Map<String, dynamic> event);
}