import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../utils/app_logger.dart';

class ConnectivityService {
  final _connectivity = Connectivity();
  late final StreamController<bool> _controller;
  StreamSubscription? _subscription;
  bool _isConnected = true;

  ConnectivityService() {
    _controller = StreamController<bool>.broadcast();
  }

  bool get isConnected => _isConnected;
  Stream<bool> get onConnectivityChanged => _controller.stream;

  /// Resolves the real network state and starts the connectivity listener.
  ///
  /// Must be awaited in [configureDependencies] before any repository or BLoC
  /// reads [isConnected]. Without this await, the default [_isConnected = true]
  /// may be returned before the first [checkConnectivity] call resolves, causing
  /// the first upload decision to act on stale data.
  ///
  /// Safe to call multiple times — subsequent calls are no-ops if already
  /// initialised.
  Future<void> initialize() async {
    // Resolve the real state before returning to the caller.
    final results = await _connectivity.checkConnectivity();
    _isConnected = results.any((r) => r != ConnectivityResult.none);
    AppLogger.info(
        'NET', 'Initial connectivity: ${_isConnected ? "ONLINE" : "OFFLINE"}');

    // Start listening for future changes.
    _subscription ??=
        _connectivity.onConnectivityChanged.listen((results) {
      final connected = results.any((r) => r != ConnectivityResult.none);
      if (connected != _isConnected) {
        _isConnected = connected;
        if (connected) {
          AppLogger.networkRestored();
        } else {
          AppLogger.networkDisconnected();
        }
        _controller.add(_isConnected);
      }
    });
  }

  Future<bool> checkConnectivity() async {
    final results = await _connectivity.checkConnectivity();
    _isConnected = results.any((r) => r != ConnectivityResult.none);
    return _isConnected;
  }

  void dispose() {
    _subscription?.cancel();
    _controller.close();
  }
}