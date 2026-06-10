import 'dart:async';

import '../network/connectivity_service.dart';
import '../utils/app_logger.dart';
import '../../features/location/domain/repositories/location_repository.dart';

/// Dedicated periodic upload worker independent of GPS events.
///
/// Runs on its own timer so uploads happen even when the device is stationary
/// (distance threshold never triggers). Uses exponential backoff on failure.
///
/// Requirements met:
///  • Runs independently of GPS updates
///  • Runs independently of connectivity callbacks
///  • Automatically drains queue
///  • Preserves ordering (oldest-first via Hive insertion order)
///  • Exponential backoff via [_backoffSeconds]
///  • Auto-restarts after dead-letter threshold via a 5-minute cooldown timer
class UploadWorker {
  final LocationRepository _repository;
  final ConnectivityService _connectivity;

  /// Overridable base interval — set to a small value in unit tests so
  /// the dead-letter threshold can be exercised without real-time delays.
  final Duration tickInterval;

  Timer? _timer;
  Timer? _restartTimer;
  bool _running = false;
  int _consecutiveFailures = 0;

  static const int _maxBackoffMultiplier = 6;
  static const int _maxConsecutiveFailures = 5;
  static const Duration _deadLetterCooldown = Duration(minutes: 5);

  UploadWorker(
    this._repository,
    this._connectivity, {
    this.tickInterval = const Duration(seconds: 10),
  });

  void start() {
    if (_running) return;
    _running = true;
    _consecutiveFailures = 0;
    _restartTimer?.cancel();
    _restartTimer = null;
    AppLogger.info('UPLOAD_WORKER', 'Worker started');
    _scheduleNext();
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    AppLogger.info('UPLOAD_WORKER', 'Worker stopped');
  }

  void _scheduleNext() {
    if (!_running) return;
    final backoff = _backoff();
    _timer = Timer(backoff, _tick);
    AppLogger.debug('UPLOAD_WORKER', 'Next upload in ${backoff.inSeconds}s');
  }

  Duration _backoff() {
    if (_consecutiveFailures == 0) return tickInterval;
    final multiplier = 1 << _consecutiveFailures.clamp(0, _maxBackoffMultiplier);
    final maxMs = tickInterval.inMilliseconds * 12; // cap at 12× base
    final ms = (tickInterval.inMilliseconds * multiplier).clamp(
      tickInterval.inMilliseconds,
      maxMs,
    );
    return Duration(milliseconds: ms);
  }

  Future<void> _tick() async {
    if (!_running) return;

    if (!_connectivity.isConnected) {
      AppLogger.debug('UPLOAD_WORKER', 'Offline — skipping tick');
      _scheduleNext();
      return;
    }

    try {
      final uploaded = await _repository.uploadPendingLocations();
      if (uploaded > 0) {
        AppLogger.info('UPLOAD_WORKER', 'Uploaded $uploaded locations');
        _consecutiveFailures = 0;
      } else {
        // Log at debug so the silence is explicit and diagnosable.
        AppLogger.debug('UPLOAD_WORKER', 'Queue empty — nothing to upload');
      }
    } catch (e) {
      _consecutiveFailures++;
      AppLogger.warn('UPLOAD_WORKER',
          'Upload failed (attempt $_consecutiveFailures/$_maxConsecutiveFailures): $e');
      if (_consecutiveFailures >= _maxConsecutiveFailures) {
        AppLogger.warn('UPLOAD_WORKER',
            'Dead-letter threshold reached — pausing worker for ${_deadLetterCooldown.inMinutes} min');
        stop();
        _restartTimer = Timer(_deadLetterCooldown, () {
          AppLogger.info('UPLOAD_WORKER', 'Dead-letter cooldown elapsed — restarting');
          start();
        });
        return;
      }
    }

    _scheduleNext();
  }

  bool get isRunning => _running;
}
