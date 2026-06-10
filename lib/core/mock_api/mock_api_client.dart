import 'dart:math';
import 'package:logger/logger.dart';
import 'package:retry/retry.dart';

import '../constants/app_constants.dart';
import '../storage/location_entry.dart';
import '../utils/app_logger.dart';

/// Contract every backend implementation must satisfy.
///
/// Implementations:
///   [MockApiClient]    — in-process simulation (development / CI)
///   [FirebaseApiClient] — real Firestore backend (production / demo)
abstract class ApiClient {
  Future<List<String>> uploadLocationBatch({
    required String tripId,
    required List<LocationEntry> locations,
    String? driverId,
  });

  Future<void> reportTripStarted(String tripId);

  Future<void> reportTripEnded({
    required String tripId,
    required int totalPoints,
  });
}

class MockApiClient implements ApiClient {
  final _logger = Logger();
  final _random = Random();

  static const double _failureRate = 0.15;
  static const Duration _minLatency = Duration(milliseconds: 120);
  static const Duration _maxLatency = Duration(milliseconds: 600);

  Future<void> _simulateNetwork() async {
    final latencyMs = _minLatency.inMilliseconds +
        _random.nextInt(
            _maxLatency.inMilliseconds - _minLatency.inMilliseconds);
    await Future.delayed(Duration(milliseconds: latencyMs));

    if (_random.nextDouble() < _failureRate) {
      throw MockNetworkException(
        'Simulated transient network error',
        statusCode: _random.nextBool() ? 503 : 500,
      );
    }
  }

  @override
  Future<List<String>> uploadLocationBatch({
    required String tripId,
    required List<LocationEntry> locations,
    String? driverId, // accepted but unused in mock
  }) async {
    if (locations.isEmpty) return [];

    int attempt = 0;
    final accepted = await retry(
      () async {
        attempt++;
        if (attempt > 1) {
          AppLogger.retryStarted(attempt - 1, AppConstants.maxRetryCount,
              Exception('previous attempt failed'));
        }
        await _simulateNetwork();

        _logger.i('[MockAPI] POST /driver/locations/batch  '
            'trip=$tripId  count=${locations.length}  attempt=$attempt');

        final ackIds = locations.map((l) => l.uuid).toList();
        return ackIds;
      },
      retryIf: (e) => e is MockNetworkException && e.isRetryable,
      maxAttempts: AppConstants.maxRetryCount,
      delayFactor: const Duration(seconds: 2),
      onRetry: (e) {
        AppLogger.warn('MOCK_API', 'Retry triggered  reason=${e.runtimeType}');
      },
    );

    if (attempt > 1) {
      AppLogger.retryCompleted(attempt);
    }

    return accepted;
  }

  @override
  Future<void> reportTripStarted(String tripId) async {
    int attempt = 0;
    await retry(
      () async {
        attempt++;
        await _simulateNetwork();
        _logger.i('[MockAPI] POST /trips/$tripId/start  attempt=$attempt');
      },
      retryIf: (e) => e is MockNetworkException && e.isRetryable,
      maxAttempts: AppConstants.maxRetryCount,
      delayFactor: const Duration(seconds: 2),
      onRetry: (e) =>
          AppLogger.warn('MOCK_API', 'Trip start retry  reason=${e.runtimeType}'),
    );
  }

  @override
  Future<void> reportTripEnded({
    required String tripId,
    required int totalPoints,
  }) async {
    int attempt = 0;
    await retry(
      () async {
        attempt++;
        await _simulateNetwork();
        _logger.i(
            '[MockAPI] POST /trips/$tripId/end  points=$totalPoints  attempt=$attempt');
      },
      retryIf: (e) => e is MockNetworkException && e.isRetryable,
      maxAttempts: AppConstants.maxRetryCount,
      delayFactor: const Duration(seconds: 2),
      onRetry: (e) =>
          AppLogger.warn('MOCK_API', 'Trip end retry  reason=${e.runtimeType}'),
    );
  }
}

class MockNetworkException implements Exception {
  final String message;
  final int statusCode;

  const MockNetworkException(this.message, {required this.statusCode});

  bool get isRetryable => statusCode >= 500;

  @override
  String toString() => 'MockNetworkException($statusCode): $message';
}