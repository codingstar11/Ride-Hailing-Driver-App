import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';

import 'package:ride_hailing_driver/core/network/connectivity_service.dart';
import 'package:ride_hailing_driver/core/services/upload_worker.dart';
import 'package:ride_hailing_driver/features/location/domain/repositories/location_repository.dart';

import 'upload_worker_test.mocks.dart';

@GenerateMocks([LocationRepository, ConnectivityService])
void main() {
  late MockLocationRepository mockRepo;
  late MockConnectivityService mockConnectivity;

  // Fast tick for all tests so we don't wait real seconds.
  const fastTick = Duration(milliseconds: 30);

  setUp(() {
    mockRepo = MockLocationRepository();
    mockConnectivity = MockConnectivityService();
    when(mockConnectivity.isConnected).thenReturn(true);
    when(mockRepo.uploadPendingLocations()).thenAnswer((_) async => 0);
  });

  test('worker starts and can be stopped', () async {
    final worker = UploadWorker(mockRepo, mockConnectivity, tickInterval: fastTick);
    expect(worker.isRunning, false);
    worker.start();
    expect(worker.isRunning, true);
    worker.stop();
    expect(worker.isRunning, false);
  });

  test('worker does not upload when offline', () async {
    when(mockConnectivity.isConnected).thenReturn(false);
    final worker = UploadWorker(mockRepo, mockConnectivity, tickInterval: fastTick);
    worker.start();
    await Future.delayed(const Duration(milliseconds: 100));
    worker.stop();
    verifyNever(mockRepo.uploadPendingLocations());
  });

  test('worker calls uploadPendingLocations when online', () async {
    when(mockConnectivity.isConnected).thenReturn(true);
    when(mockRepo.uploadPendingLocations()).thenAnswer((_) async => 5);

    final worker = UploadWorker(mockRepo, mockConnectivity, tickInterval: fastTick);
    worker.start();
    // Wait for at least two ticks.
    await Future.delayed(const Duration(milliseconds: 150));
    worker.stop();
    verify(mockRepo.uploadPendingLocations()).called(greaterThan(0));
  });

  test('consecutive failures increment counter and worker stops at threshold', () async {
    when(mockConnectivity.isConnected).thenReturn(true);
    when(mockRepo.uploadPendingLocations()).thenThrow(Exception('network failure'));

    final worker = UploadWorker(mockRepo, mockConnectivity, tickInterval: fastTick);
    worker.start();

    // With fastTick=30ms and 5 failures needed, 5 * 30ms ≈ 150ms + some slack.
    // The backoff doubles each time so total time for 5 failures:
    //   tick 1: 30ms, tick 2: 60ms, tick 3: 120ms, tick 4: 240ms, tick 5: 360ms
    // Cap at 12x base = 360ms. Wait generously.
    await Future.delayed(const Duration(milliseconds: 2000));

    // After 5 consecutive failures the worker should have stopped itself.
    expect(worker.isRunning, false);
    verify(mockRepo.uploadPendingLocations()).called(5);
  });

  test('worker resets failure counter after a successful upload', () async {
    var callCount = 0;
    when(mockConnectivity.isConnected).thenReturn(true);
    when(mockRepo.uploadPendingLocations()).thenAnswer((_) async {
      callCount++;
      // Fail on first 3 calls, succeed on the 4th.
      if (callCount < 4) throw Exception('transient failure');
      return 3;
    });

    final worker = UploadWorker(mockRepo, mockConnectivity, tickInterval: fastTick);
    worker.start();
    await Future.delayed(const Duration(milliseconds: 2000));
    worker.stop();

    // Worker should still be running (or have completed gracefully).
    // The key assertion: it was not stopped early by dead-letter threshold.
    verify(mockRepo.uploadPendingLocations()).called(greaterThanOrEqualTo(4));
  });

  test('starting twice is idempotent — only one timer runs', () async {
    when(mockConnectivity.isConnected).thenReturn(true);
    when(mockRepo.uploadPendingLocations()).thenAnswer((_) async => 0);

    final worker = UploadWorker(mockRepo, mockConnectivity, tickInterval: fastTick);
    worker.start();
    worker.start(); // second call should be a no-op
    await Future.delayed(const Duration(milliseconds: 150));
    worker.stop();

    // If two timers ran concurrently the call count would roughly double.
    // With a single timer and ~5 ticks in 150ms at 30ms base, expect ~5 calls.
    // Verify it didn't balloon to 10+.
    final callCount = verify(mockRepo.uploadPendingLocations()).callCount;
    expect(callCount, lessThan(10));
  });
}
