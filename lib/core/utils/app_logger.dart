import 'package:logger/logger.dart';

class AppLogger {
  static final Logger _i = Logger(
    printer: _ColoredPrinter(),
    level: Level.debug,
  );

  static String _ts() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}'
        '.${now.millisecond.toString().padLeft(3, '0')}';
  }

  // ── Trip lifecycle ──────────────────────────────────────────────────────

  static void tripStarted(String tripId) {
    _i.i('🚀 ══════ TRIP STARTED ══════  tripId=$tripId  time=${_ts()}');
  }

  static void tripStopped(String tripId, {required int totalPoints}) {
    _i.i('🏁 ══════ TRIP STOPPED ══════  tripId=$tripId  totalPoints=$totalPoints  time=${_ts()}');
  }

  // ── Location ────────────────────────────────────────────────────────────

  static void locationReceived({
    required double lat,
    required double lng,
    required double accuracy,
    double? speed,
  }) {
    _i.d('📍 [GPS] Location received  '
        'lat=${lat.toStringAsFixed(6)}  '
        'lng=${lng.toStringAsFixed(6)}  '
        'acc=${accuracy.toStringAsFixed(1)}m  '
        'speed=${speed?.toStringAsFixed(1) ?? '?'}m/s');
  }

  static void locationSavedToHive(String uuid, String tripId) {
    _i.d('💾 [HIVE] Location saved  uuid=${uuid.substring(0, 8)}…  trip=$tripId');
  }

  static void locationQueued(String uuid) {
    _i.d('📥 [QUEUE] Location queued  uuid=${uuid.substring(0, 8)}…');
  }

  static void locationDiscarded(double accuracy) {
    _i.w('🚫 [GPS] Discarded inaccurate point  '
        'acc=${accuracy.toStringAsFixed(1)}m  threshold=50m');
  }

  static void locationEmittedToUi(double lat, double lng) {
    _i.d('🖥  [UI] Location emitted to stream  lat=$lat  lng=$lng');
  }

  // ── Upload ──────────────────────────────────────────────────────────────

  static void uploadStarted(int count, String tripId) {
    _i.i('☁  [UPLOAD] Upload started  count=$count  trip=$tripId');
  }

  static void uploadSuccess(int count) {
    _i.i('✅ [UPLOAD] Upload SUCCESS  confirmed=$count  time=${_ts()}');
  }

  static void uploadFailed(Object err) {
    _i.e('❌ [UPLOAD] Upload FAILED  error=$err');
  }

  static void retryStarted(int attempt, int maxAttempts, Object err) {
    _i.w('🔄 [RETRY] Retry $attempt/$maxAttempts  reason=${err.runtimeType}');
  }

  static void retryCompleted(int totalAttempts) {
    _i.i('✅ [RETRY] Retry completed after $totalAttempts attempt(s)');
  }

  static void retryExhausted(int maxAttempts) {
    _i.e('❌ [RETRY] All $maxAttempts attempts exhausted — giving up');
  }

  // ── Network ─────────────────────────────────────────────────────────────

  static void networkDisconnected() {
    _i.w('📵 [NET] ══ Network DISCONNECTED ══  Queue mode active');
  }

  static void networkRestored() {
    _i.i('📶 [NET] ══ Network RESTORED ══  Draining offline queue…');
  }

  // ── Permissions ─────────────────────────────────────────────────────────

  static void locationServicesDisabled() {
    _i.e('❌ [PERM] Location services DISABLED on device');
  }

  static void permissionGranted(String permission) {
    _i.i('🔓 [PERM] Permission GRANTED  type=$permission');
  }

  static void permissionDenied(String permission) {
    _i.w('🔒 [PERM] Permission DENIED  type=$permission');
  }

  static void backgroundPermissionGranted() {
    _i.i('🔓 [PERM] Background (Always) permission GRANTED');
  }

  static void backgroundPermissionRequired() {
    _i.w('⚠  [PERM] Only "While In Use" granted — '
        'background tracking requires "Always Allow"');
  }

  static void permissionPermanentlyDenied(String permission) {
    _i.e('🚫 [PERM] Permission PERMANENTLY DENIED  type=$permission  '
        '→ directing user to Settings');
  }

  // ── GPS accuracy ─────────────────────────────────────────────────────────

  static void gpsAccuracyIssue(double accuracy) {
    _i.w('📡 [GPS] Low accuracy  ${accuracy.toStringAsFixed(0)}m  (threshold=50m)');
  }

  // ── App lifecycle ─────────────────────────────────────────────────────────

  static void appResumed() {
    _i.i('▶  [LIFECYCLE] ══ App RESUMED ══  (foreground)');
  }

  static void appPaused() {
    _i.i('⏸  [LIFECYCLE] ══ App PAUSED ══  (background transition)');
  }

  static void appInBackground() {
    _i.i('🌑 [LIFECYCLE] App in BACKGROUND — background service tracking');
  }

  static void appReturnedToForeground() {
    _i.i('🌕 [LIFECYCLE] App returned to FOREGROUND');
  }

  static void appDetached() {
    _i.i('⏹  [LIFECYCLE] App DETACHED');
  }

  static void appInactive() {
    _i.d('⚬  [LIFECYCLE] App INACTIVE');
  }

  // ── Background service ───────────────────────────────────────────────────

  static void backgroundServiceStarted() {
    _i.i('🟢 [BG_SVC] Background service STARTED');
  }

  static void backgroundServiceStopped() {
    _i.i('🔴 [BG_SVC] Background service STOPPED');
  }

  static void backgroundServiceHeartbeat(int count, DateTime ts) {
    _i.d('💓 [BG_SVC] Heartbeat #$count  ts=${ts.toIso8601String()}');
  }

  static void backgroundServiceError(Object err) {
    _i.e('❌ [BG_SVC] Service error  $err');
  }

  // ── Telemetry ────────────────────────────────────────────────────────────

  static void telemetryPersisted(String event) {
    _i.d('📊 [TELEMETRY] Persisted event=$event');
  }

  // ── Generic ──────────────────────────────────────────────────────────────

  static void info(String tag, String msg) => _i.i('ℹ  [$tag] $msg');
  static void warn(String tag, String msg) => _i.w('⚠  [$tag] $msg');
  static void error(String tag, String msg, [Object? err]) =>
      _i.e('❌ [$tag] $msg${err != null ? '\n    $err' : ''}');
  static void debug(String tag, String msg) => _i.d('🔍 [$tag] $msg');
}

class _ColoredPrinter extends LogPrinter {
  static const Map<Level, String> _colors = {
    Level.trace:    '\x1B[90m',   // Gray
    Level.debug:    '\x1B[36m',   // Cyan
    Level.info:     '\x1B[32m',   // Green
    Level.warning:  '\x1B[33m',   // Yellow
    Level.error:    '\x1B[31m',   // Red
    Level.fatal:    '\x1B[35m',   // Magenta
  };

  static const String _reset = '\x1B[0m';

  @override
  List<String> log(LogEvent event) {
    final color = _colors[event.level] ?? '\x1B[37m'; // Default white
    final time = DateTime.now().toIso8601String().substring(11, 23);
    
    // Build the prefix: [TIME LEVEL] 
    final prefix = '[$time ${event.level.name.toUpperCase().padRight(7)}]';
    
    // Wrap the ENTIRE line in color, not just a small box
    return ['$color$prefix ${event.message}$_reset'];
  }
}