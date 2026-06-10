# Technical Discussion

---

## Scenario A — Xiaomi Devices: Background Tracking Stops After 15 Minutes

### Problem

On Xiaomi devices running MIUI, the background service stops collecting GPS fixes approximately 15 minutes after the app moves to the background, even though the app declares a foreground service with `foregroundServiceType="location"`. Drivers report missing route segments starting 15–20 minutes into a trip.

### Investigation Strategy

**Step 1: Reproduce consistently.**
Install a debug build on a Xiaomi Mi or Redmi device. Start a trip, lock the screen, and monitor logcat output filtered to the background service tag. Note the exact timestamp when GPS events stop appearing.

**Step 2: Check MIUI AutoStart.**
Navigate to Settings → Apps → Manage Apps → [App Name] → Other Permissions. Confirm whether "Autostart" and "Background pop-up" are enabled. MIUI's aggressive battery manager treats apps without these permissions as restricted even when they hold a foreground service.

**Step 3: Check battery optimisation exemption.**
Navigate to Settings → Battery & Performance → App Battery Saver. If the app is not exempted, MIUI throttles and eventually kills foreground services on a 15-minute cycle (the "15-minute window" seen in MIUI 12+).

**Step 4: Examine `device_vendor_service.dart`.**
The app detects Xiaomi/MIUI at startup via `DeviceVendorService`. Verify that `isXiaomi` returns `true` on affected devices and that the guidance dialog in `xiaomi_guidance_dialog.dart` is being surfaced before the first trip.

**Step 5: Review the foreground service notification.**
MIUI will terminate a foreground service if its notification is dismissed or if the notification channel is set to `IMPORTANCE_NONE`. Confirm the notification channel is at least `IMPORTANCE_LOW` and that the notification is not dismissible.

**Step 6: Verify foreground service wake-lock configuration.**
The application does not use a separate wake-lock package. Instead, wake-lock management is handled by Geolocator's Android foreground service configuration:

```dart
foregroundNotificationConfig: const ForegroundNotificationConfig(
  notificationTitle: 'Driver Tracking Active',
  notificationText: 'Tracking your location',
  enableWakeLock: true,
),
```

I would verify that the foreground service remains active after screen lock, extended background execution, and app minimization. If tracking still stops after approximately 15 minutes, the likely root cause is MIUI battery management rather than wake-lock configuration.

### Resolution Strategy

**Programmatic fix (already implemented):**
- Detect MIUI via `DeviceVendorService`.
- Show `XiaomiGuidanceDialog` before the first trip to walk the driver through enabling Autostart and battery exemption.
- Enable Geolocator's built-in foreground-service wake lock using `ForegroundNotificationConfig(enableWakeLock: true)` to help prevent CPU suspension during active location tracking.


**AndroidManifest additions:**
```xml
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>
```
Prompt the user to whitelist the app via `android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`.

**MIUI-specific restart intent:**
On certain MIUI versions, sending a self-restart broadcast after the service warms up (`am startservice`) re-registers the service under the higher-priority "user-facing" slot, extending the window indefinitely.

**Monitoring:** Tag all background isolate GPS events with the device model and MIUI version in the Hive telemetry log. Aggregate in Firestore to identify which specific firmware versions regress.

---

## Scenario B — Missing Route Points

### Problem

Post-trip route playback shows gaps. Some trips have a continuous polyline for the first 20 minutes, then isolated clusters of points with large time gaps between them, producing a disconnected route.

### Root Cause Analysis

Missing route points typically originate from one of four causes:

**1. GPS silence (hardware/OS level).**
The device temporarily stopped emitting GPS events. Can happen when the screen locks on some OEMs, when the GPS hardware enters a low-power state, or when the Geolocator stream is interrupted by a service restart. Detectable by comparing the timestamp gap between consecutive `LocationEntry` records in the Hive queue against the configured `locationIntervalSeconds`.

**2. Accuracy filter too aggressive.**
The background service discards fixes where `position.accuracy > CountryConfig.minAccuracyMeters`. In urban canyons or during bad weather, GPS accuracy can degrade to 80–120 m for minutes at a time, causing all fixes to be dropped.

**3. Upload pipeline without Hive save.**
If a code path calls the API directly without saving to Hive first, a network failure causes permanent data loss. In this implementation the background isolate always saves to Hive first (see `BackgroundServiceHandler`), but this must be audited for any race condition in the Hive box-open sequence.

**4. Partial ACK deletes wrong entries.**
If the ACK UUID list has an off-by-one error, correct entries may be deleted while failed ones remain. The `deleteConfirmed` test in `connectivity_recovery_test.dart` guards against this.

### Telemetry Strategy

Every GPS fix lifecycle event is written to the Hive `telemetry` LazyBox with a millisecond-precision timestamp and a structured payload:

- `location_saved` — emitted after every successful Hive write, includes UUID, lat, lng, accuracy.
- `location_uploaded` — emitted after server ACK, includes batch size and ACK count.
- `upload_failed` — emitted on upload exception, includes `retryCount`.
- `service_started` / `service_killed` — emitted at background isolate lifecycle boundaries.
- `connectivity_restored` — emitted when `ConnectivityService` fires `true`.

Post-incident, these events can be exported from the device (adb shell or Firestore mirror) and correlated with the server-side trip record to pinpoint where the gap occurred.

### Logging Strategy

`AppLogger` writes structured log lines at DEBUG/INFO/WARN/ERROR levels. In production, wrap `AppLogger` with a remote sink (e.g. Firebase Crashlytics custom logs or a dedicated logging endpoint) so telemetry is available without physical device access.

Log every fix with: `timestamp | lat | lng | accuracy | tripId | retryCount | queueLength`.

Log every upload batch with: `timestamp | tripId | batchSize | ackCount | durationMs | httpStatus`.

Alert if `timestamp_gap > locationIntervalSeconds * 3` between consecutive saved entries for a given trip.

---

## Scenario C — Battery Consumption Increased by 40%

### Problem

After a recent release, driver reports and Play Store reviews indicate significantly higher battery drain. The app's background service is suspected.

### Investigation Strategy

**Step 1: Reproduce with battery historian.**
Run `adb bugreport` before and after a 30-minute trip. Import the bug report into Android Battery Historian. Look for:
- Wakelock held time.
- Job scheduler / alarm wakeups.
- Foreground service CPU time in the app's UID.
- GPS sensor active duration.

**Step 2: Instrument the background isolate.**
Add millisecond timestamps around the Hive write, upload call, and ACK delete in the background isolate. Log the total wall-clock time per GPS tick. A tick that consistently takes >500 ms indicates the upload is blocking the GPS event loop, keeping the CPU busy.

**Step 3: Check location stream settings.**
`locationIntervalSeconds` and `locationDistanceMeters` are country-configurable. Confirm the values were not accidentally changed in the last release. A reduction from 5 s to 1 s would triple CPU and GPS usage.

**Step 4: Review foreground service lifecycle.**
The application relies on Geolocator's foreground service configuration rather than manual wake-lock management. I would verify that tracking is only active during an active trip and that the foreground service is stopped correctly when tracking ends.

I would also confirm that:

* No orphaned foreground services remain running after trip completion.
* `enableWakeLock: true` is only active while tracking is active.
* GPS subscriptions are cancelled correctly when the trip ends.
* Background uploads are not continuously retrying due to configuration issues.

A foreground service that remains active after trip completion can contribute to unnecessary battery drain.

**Step 5: Profile the Hive write path.**
A LazyBox with thousands of entries causes O(n) key iteration in `getPendingLocations`. On a long-running device with a large backlog (driver offline for hours), this scan runs on every GPS tick. Use `Timeline.startSync` / `finishSync` to measure.

### Metrics to Analyse

| Metric | Tool | Threshold |
|---|---|---|
| Battery drain rate (mAh/h) | Battery Historian, Firebase Performance | <5% per hour with GPS active |
| GPS fix latency (ms) | AppLogger custom timing | <200 ms per fix |
| Hive write latency (ms) | AppLogger custom timing | <50 ms |
| Upload batch duration (ms) | AppLogger custom timing | <2 s for 50-entry batch |
| Wake lock held time | Battery Historian | Only during active trip |
| Background CPU time | Battery Historian | <5% of trip duration |

### Optimisation Strategy

**GPS interval tuning:** Increase `locationDistanceMeters` from 20 m to 50 m for urban trips where the driver is frequently stopped. This reduces GPS events by 60% in stop-and-go traffic without meaningful route quality loss.

**Decouple Hive write from upload:** In the current design the background isolate attempts an upload on every GPS tick. For low-connectivity scenarios this results in repeated failed network calls that keep the radio awake (radio tail problem). Change to: save to Hive on every tick; upload only when `pendingCount >= batchSize` OR on the periodic UploadWorker tick. This reduces radio wakeup events significantly.

**Lazy wake lock:** Acquire the partial wake lock only during the active Hive-write + upload window (typically <100 ms per tick), then release it immediately. Do not hold it for the entire GPS interval.

**Batch size increase:** Increase `batchUploadSize` from 50 to 100. Fewer upload calls per trip means less radio activation time.

**Country-specific intervals:** Reduce tracking frequency in countries with good road networks and lower dispute rates (GB, AE) without impacting PK where dense traffic requires tighter intervals.

---

## Scenario D — Expansion to 15 Countries

### Country Configuration

Each country is represented by a `CountryConfig` object with these fields:

```dart
class CountryConfig {
  final String countryCode;
  final MapProvider mapProvider;           // google | mapbox | here
  final List<PaymentProvider> paymentProviders;
  final List<String> enabledFeatures;      // feature flag keys
  final String currencyCode;
  final String distanceUnit;               // 'km' | 'miles'
  final double locationIntervalSeconds;    // GPS poll interval
  final double minAccuracyMeters;          // accuracy gate
  final double locationDistanceMeters;     // minimum movement to record
  final bool requiresNationalId;
}
```

Defaults for Pakistan (PK), UAE (AE), Great Britain (GB), United States (US), Egypt (EG), and Nigeria (NG) are bundled in `country_config.dart`. On first launch the config for the driver's ISO country code is loaded from the Hive `config` box. A background fetch updates the config from a CDN endpoint and persists the result — subsequent launches use the cached version even without network access.

### Feature Flags

`enabledFeatures` is a `List<String>` of string keys. Feature flag checks are performed at the call site:

```dart
if (config.enabledFeatures.contains('scheduled_rides')) { ... }
```

This avoids a separate feature-flag SDK and keeps the flag state co-located with the country config. Remote config updates push a new `CountryConfig` JSON that includes updated flag lists.

### Payment Providers

`paymentProviders` is a `List<PaymentProvider>` enum. The payment widget reads this list and renders only the enabled options. Each payment provider is implemented behind a common `PaymentClient` interface analogous to `ApiClient`, injected via `configureDependencies`.

| Region | Providers |
|---|---|
| PK | JazzCash, cash |
| AE | HyperPay, Stripe |
| GB / US | Stripe |
| EG | Paytm, cash |
| NG | cash |

### Map Providers

`mapProvider` selects the map SDK:

- `MapProvider.google` — `google_maps_flutter`
- `MapProvider.mapbox` — `mapbox_maps_flutter`
- `MapProvider.here` — `here_sdk`

`MapProviderWidget` in `map_provider_widget.dart` renders the correct widget based on `CountryConfig.mapProvider`. The `MapBloc` is backend-agnostic — it receives `MapLocation` entities regardless of which SDK sourced them.

---

## System Design Exercise

### Assumptions

- 50,000 drivers online simultaneously.
- Each driver emits a location every 3 seconds.
- Total ingest rate: 50,000 / 3 ≈ 16,700 location writes/second.
- Each location payload: ~200 bytes JSON.
- Total ingest bandwidth: ~3.3 MB/s sustained.

---

### Mobile Architecture

**Background isolate** owns the complete persistence + upload pipeline. The main Flutter isolate is display-only. This separation means app swipe-away, navigation away, or UI freeze does not interrupt data collection.

**Hive queue** acts as a write-ahead log. Every fix is durably persisted before any network attempt. The queue is the source of truth until the server ACKs.

**Batching** reduces write amplitudes. Batch size of 50 locations at 3-second intervals means one upload call per 2.5 minutes of driving — acceptable for both battery and server load.

**Event deduplication** at the server side: each location entry has a stable UUID generated on-device. The server uses this as an idempotency key on upsert, so retried batches do not produce duplicates.

---

### Offline Strategy

Three tiers of offline tolerance:

**Tier 1 — Short outage (< 5 minutes):** `UploadWorker` retries automatically. Queue grows by ~100 entries. No user intervention required.

**Tier 2 — Medium outage (5–60 minutes):** Worker pauses after 5 consecutive failures. Queue may grow to 1,200 entries (~240 KB). On reconnection, `UploadWorker` restarts (after 5-minute cooldown) and drains the queue in ~24 upload batches.

**Tier 3 — Extended outage (> 60 minutes or process kill):** On next app launch, `TripRestorationRequested` is fired, the active trip ID is read from Hive, `resumeTracking` is called, and the UploadWorker starts draining immediately.

Device-offline detection uses `ConnectivityService` (backed by `connectivity_plus`). The worker skips ticks when `isConnected == false` to avoid wasting battery on doomed HTTP calls.

---

### Retry Strategy

Per-request retries (inside `ApiClient` implementations): up to 5 attempts, exponential backoff with a 2-second base delay, retryable only for 5xx responses. 4xx (client errors) are not retried — they indicate a payload problem that will not self-heal.

Queue-level retries (UploadWorker): periodic background drain that is completely independent of the per-request retry. This ensures entries survive even if all per-request retries are exhausted in a given session.

Dead-letter handling: after 5 consecutive UploadWorker failures, the worker pauses for 5 minutes. This prevents the dead-letter queue from hammering a degraded server. After the cooldown, the worker resumes. If the `retryCount` of an entry exceeds a configurable threshold (e.g. 20), the entry can be moved to a separate dead-letter Hive box for manual review without blocking the live queue.

---

### Sync Strategy

The sync model is **append-only write** with server-ACK-driven deletion:

1. Client writes to local Hive queue (write-ahead log).
2. Client uploads a batch to the server.
3. Server persists the batch and returns ACK UUIDs.
4. Client deletes ACK'd entries from Hive.

There is no read-sync required — the server is the system of record for the canonical trip record. The mobile device only reads back trip data for display purposes (outside the scope of this challenge).

Conflict resolution is trivial because locations are immutable once written. Two uploads of the same UUID (retry scenario) are idempotent upserts at the server side.

---

### Battery Optimisation

**GPS interval:** 5 seconds default (3 seconds for UAE per `CountryConfig`). Geolocator's `LocationSettings.distanceFilter` adds a minimum movement gate (20 m) so stationary drivers do not generate unnecessary events.

**Foreground service wake lock:** Managed by Geolocator through `ForegroundNotificationConfig(enableWakeLock: true)`. Battery investigations should verify that tracking sessions and foreground services are terminated correctly when trips end, preventing unnecessary background CPU activity.

**Radio batching:** Accumulate 50 locations before uploading. A single HTTP request for 50 locations consumes far less radio energy than 50 individual requests (eliminates the radio tail 50 times).

**Accuracy gate:** Fixes with `accuracy > minAccuracyMeters` are discarded before any Hive write. This reduces write I/O and prevents noisy urban-canyon fixes from polluting the route.

**Adaptive interval (future):** When `speed < 2 km/h` for > 30 seconds (driver stationary at a red light), reduce GPS polling to once per 10 seconds. Restore to the standard interval when speed increases above a threshold.

---

### Real-Time Communication

For the current challenge scope, communication is unidirectional (driver → server). At 50,000 drivers × 1 write/3s the server must handle ~17,000 writes/second.

**Server architecture recommendation:**

An ingest tier (stateless HTTP workers) accepts batch uploads and writes to a message queue (Kafka or Google Pub/Sub). A consumer tier reads from the queue and writes to the storage backend (Firestore or a time-series database). This decouples write latency from storage latency and provides natural back-pressure.

**For passenger-facing real-time tracking (bidirectional):**

Replace the polling upload with a persistent WebSocket or MQTT connection. The background isolate streams fixes to the broker, which fan-outs to passenger clients subscribed to that driver's topic. This reduces mobile latency to <200 ms and eliminates the upload batch delay.

At 50,000 concurrent WebSocket connections, use a connection-multiplexing gateway (e.g. Google Cloud Pub/Sub, MQTT broker, or a dedicated WebSocket service with horizontal scaling). Each driver connection is ~2 KB idle memory; 50,000 connections ≈ 100 MB at the gateway tier — manageable with a small cluster.

---

## Additional Technical Questions

### Q: How would you ensure no location point is lost if the phone is switched off mid-trip?

The Hive queue is the answer. Because every fix is written to Hive before any upload attempt, a sudden power-off leaves all un-ACK'd entries on disk. On the next power-on and app launch, `TripRestorationRequested` fires, `getActiveTripId()` returns the persisted trip ID, `resumeTracking()` re-subscribes the background service, and `UploadWorker` drains the queue from the point of the last ACK'd batch. No fix is permanently lost unless the device storage is physically corrupted.

### Q: How do you prevent duplicate location entries at the server?

Each `LocationEntry` has a UUID generated on the device at the time the fix is received. The server uses this UUID as a document ID (Firestore) or a unique constraint key (SQL). Upsert semantics mean a retried batch with the same UUIDs is a no-op at the database level. The server ACK list for a duplicate upload correctly returns all UUIDs, allowing the client to clean up its queue normally.

### Q: How would you extend this to support multiple simultaneous drivers on a shared device (tablet dispatch)?

Add a `driverId` field to `LocationEntry` and `CountryConfig`. All Hive box keys are prefixed by `driverId` to namespace the queues. The `DriverProfileService` manages a list of profiles. Each active driver gets their own `LocationBloc` instance and `UploadWorker`. Background service receives `driverId` as a configuration parameter and tags every saved entry with it.

### Q: How does the app behave during a Geolocator stream error (e.g. GPS hardware fault)?

The background service subscribes to `Geolocator.getPositionStream` with an `onError` handler. On error, it logs the event to the Hive telemetry box (event: `gps_stream_error`), waits 5 seconds, and resubscribes. The error is also sent to the main isolate via the `onError` event bus, where `MapBloc` logs it. The driver's existing queued fixes remain in Hive and will be uploaded on the next successful tick.

### Q: What would a CI/CD pipeline for this app look like?

```
On every PR:
  1. flutter analyze
  2. flutter test test/unit/
  3. flutter build apk --debug (smoke build)

On merge to main:
  4. flutter build apk --release
  5. flutter build ios --release (Xcode Cloud)
  6. fastlane supply (upload to Play Internal Track)
  7. fastlane pilot (upload to TestFlight)

On release tag:
  8. Promote from Internal to Production (Play Store)
  9. Submit for App Store review
```

Unit tests run in <30 seconds without a device because all Hive tests use `Directory.systemTemp` and all network tests use `MockApiClient`. No emulator is required in CI.

### Q: How would you instrument this app for a production SLA?

Three observability pillars:

**Metrics:** Emit a counter `location.saved`, `location.uploaded`, `upload.failed`, `queue.depth` from the background isolate to Firebase Performance (or a custom metrics sink). Alert if `queue.depth > 200` for > 10 minutes (indicates persistent upload failure) or if `location.saved` rate drops to 0 for > 30 seconds during an active trip (GPS silence).

**Traces:** Firebase Performance automatic network monitoring captures HTTP latency and error rates for the upload endpoint. Add a custom trace wrapping the Hive-write → upload → ACK-delete cycle to measure end-to-end latency.

**Logs:** `AppLogger` writes structured lines to the Hive telemetry box. A background export job uploads the telemetry box to Firestore at trip end, making it available for post-incident analysis without requiring physical device access.