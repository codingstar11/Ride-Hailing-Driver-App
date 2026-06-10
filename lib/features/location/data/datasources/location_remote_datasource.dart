import 'package:logger/logger.dart';

import '../../../../core/mock_api/mock_api_client.dart';
import '../../../../core/storage/location_entry.dart';

/// Remote datasource — delegates to the injected [ApiClient].
///
/// Callers (repositories) are fully insulated from which backend is active.
/// Switch backends by injecting a different [ApiClient] in injection.dart.
class LocationRemoteDatasource {
  final ApiClient _apiClient;
  final _logger = Logger();

  LocationRemoteDatasource(this._apiClient);

  /// Uploads a batch of [LocationEntry] objects for [tripId].
  /// Returns the list of UUIDs the server acknowledged.
  Future<List<String>> uploadLocationBatch({
    required List<LocationEntry> locations,
    required String tripId,
    String? driverId,
  }) async {
    if (locations.isEmpty) return [];

    try {
      final ackIds = await _apiClient.uploadLocationBatch(
        tripId: tripId,
        locations: locations,
        driverId: driverId,
      );
      _logger.i(
          '[RemoteDS] Uploaded ${ackIds.length}/${locations.length} for trip $tripId');
      return ackIds;
    } catch (e) {
      _logger.e('[RemoteDS] Upload failed after retries: $e');
      rethrow;
    }
  }

  Future<void> reportTripStarted(String tripId) async {
    try {
      await _apiClient.reportTripStarted(tripId);
      _logger.i('[RemoteDS] Trip started reported: $tripId');
    } catch (e) {
      _logger.w('[RemoteDS] reportTripStarted failed (non-critical): $e');
    }
  }

  Future<void> reportTripEnded({
    required String tripId,
    required int totalPoints,
  }) async {
    try {
      await _apiClient.reportTripEnded(tripId: tripId, totalPoints: totalPoints);
      _logger.i('[RemoteDS] Trip ended reported: $tripId, points=$totalPoints');
    } catch (e) {
      _logger.w('[RemoteDS] reportTripEnded failed (non-critical): $e');
    }
  }
}