# Technical Discussion

---

## 1. Xiaomi Scenario — User Grants "Always Allow" but Tracking Stops at Night

### Root cause

MIUI (Xiaomi's Android skin) applies two independent kill mechanisms beyond
standard Android battery optimisation:

1. **AutoStart** — prevents apps from self-restarting after the OS kills them.
   Even with `RECEIVE_BOOT_COMPLETED` in the manifest the app cannot restart
   unless AutoStart is explicitly enabled by the user.
2. **Battery saver / MIUI battery optimisation** — kills foreground services on
   a schedule the user does not see, typically 5–10 minutes after the screen
   locks overnight.

Standard Android's `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` dialogue (handled by
`PermissionService.request()`) does NOT cover MIUI AutoStart — it is a separate
permission managed only inside MIUI's own Settings → App Manager.

### What the app does

- `PermissionService.request()` requests `ignoreBatteryOptimizations` and
  `activityRecognition` on Android.
- `DeviceVendorService` detects Xiaomi/Redmi/POCO devices.
- `XiaomiGuidanceDialog` shows a step-by-step screenshot-guided dialog
  instructing the driver to enable AutoStart and set battery mode to
  "No restrictions".
- `flutter_background_geolocation` sets `foregroundService: true` and
  `enableHeadless: true`. The native foreground service with a persistent
  notification survives most MIUI kill patterns, but AutoStart must still
  be granted.
- `startOnBoot: true` + `TSDeviceBootReceiver` recovers tracking after a
  full device reboot.

### Remaining gap

If MIUI kills the foreground service and AutoStart is not enabled, the plugin
cannot restart itself. The `BootReceiver.checkAndRestoreIfNeeded()` call in
`main()` recovers when the user next opens the app, uploading any queued
Hive entries and restarting the plugin. Points during the killed window are
lost unless the driver re-opens the app.

---

## 2. Missing Route Points

### Causes and mitigations

| Cause | Mitigation |
|---|---|
| GPS accuracy too low | Accuracy gate (50 m default for PK). Noisy fixes are discarded before saving to Hive. |
| Device stationary | Plugin's motion detection reduces sampling but does not stop entirely (`stopOnStationary: false`). Heartbeat at 5 s keeps the sequence alive. |
| App process killed | `enableHeadless: true` keeps the native service alive. Hive queue is flushed on next connection. |
| Network offline during upload | Write-first-then-upload design. All fixes go to Hive before any upload is attempted. UploadWorker retries periodically. |
| Plugin paused on iOS | `pausesLocationUpdatesAutomatically: false` prevents Core Location from auto-pausing after ~170 s in background. |

### Sequence numbers

Each `LocationEntry` carries a `sequenceNumber` incremented per trip. Gaps in
the sequence in Firestore indicate missed points. The `telemetry` Hive box
logs `location_discarded` events with accuracy value for post-trip analysis.

---

## 3. Battery Consumption

### Plugin behaviour

`flutter_background_geolocation` uses the native fused location API on Android
(Google Play Services) and Core Location on iOS. Both apply hardware-level
batching — the GPS chip fires only when needed, not on a polling timer.

Key settings and their battery impact:

| Setting | Value | Impact |
|---|---|---|
| `distanceFilter` | 20 m | GPS wakes only after 20 m movement |
| `heartbeatInterval` | 5 s | Periodic wake when stationary (low cost) |
| `desiredAccuracy` | HIGH | More accurate but higher power |
| `activityRecognitionInterval` | 10 000 ms | Activity sampling cost (low) |
| `minimumActivityRecognitionConfidence` | 75 % | Reduces false positives |
| `stopOnStationary` | false | Continues tracking (deliberate for trip accuracy) |

### Trade-off decisions

- **distanceFilter: 20 m** — primary trigger. GPS wakes only when the vehicle
  moves 20 m. In city traffic (stop-start) this is frequent; on a motorway it
  is less frequent. Battery consumption is proportional to distance driven,
  not time.
- **heartbeatInterval: 5 s** — ensures at least one point every 5 s regardless
  of distance, meeting the challenge requirement. The heartbeat is a timer-based
  wake that costs less than a full GPS fix; the plugin uses the last known
  position for heartbeat events when the device is stationary.
- **desiredAccuracy: HIGH** — necessary for 20 m accuracy. MEDIUM would save
  battery but produce points 50–100 m apart, degrading route quality.

For AE (`locationIntervalSeconds: 3`, `minAccuracyMeters: 30`) the GPS is
active more frequently, increasing battery draw proportionally.

---

## 4. Country Expansion

### Adding a new country

1. Add a `static const CountryConfig xx` entry to `CountryConfig` with the
   appropriate interval, distance filter, accuracy threshold, payment
   providers, and feature flags.
2. Add `'XX': CountryConfig.xx` to `_bundledDefaults` in `ConfigService`.
3. The config is applied at trip start via `BackgroundServiceHandler.applyCountryConfig()`
   which calls `BackgroundGeolocation.setConfig()` — no restart needed.
4. Remote config override: call `ConfigService.cacheConfig(remoteConfig)` with
   a server-fetched `CountryConfig` to override the bundled default.

### Per-country plugin tuning

`CountryConfig` drives three plugin parameters:

- `heartbeatInterval` ← `locationIntervalSeconds`
- `distanceFilter` ← `locationDistanceMeters`
- Accuracy gate (in `BackgroundServiceHandler._accuracyThreshold`) ← `minAccuracyMeters`

Map provider, payment provider, and feature flags are independent of the
location plugin and handled by the UI and repository layers.

---

## 5. System Design for 50,000 Active Drivers

### Write path

Each driver emits up to 12 location points/minute (5 s interval). At
50,000 drivers that is **600,000 writes/minute** (10,000 writes/second).

Firestore can handle this with the following design:

**Collection structure**

```
trips/{tripId}/locations/{uuid}
```

- `tripId` is a UUID generated client-side — no central counter, no hot spot.
- `uuid` per location point — also client-side, no sequence contention.
- One Firestore document per location point — ~300 bytes each.

**Firestore limits**

- 1 write/second per *document*. With one doc per point and UUID keys, each
  driver writes to a different document on every event — no contention.
- Firestore's write limit is per database, not per collection. At 10,000
  writes/second a single Firestore database approaches limits. Mitigation:
  shard by country code or use multiple Firestore projects behind a Cloud
  Run API layer.

**Recommended production design**

```
Driver → Cloud Run API → Pub/Sub topic → Dataflow / Cloud Functions → BigQuery
                      ↘ Firestore (live view for dispatchers)
```

- Cloud Run API validates JWT, batches the driver's points (already batched
  by `batchUploadSize: 50`), and publishes to Pub/Sub.
- A Dataflow pipeline writes to BigQuery for analytics and Firestore for the
  live dispatcher map.
- Firestore holds only the last N points per trip for live display; historical
  data lives in BigQuery.

### Read path (dispatcher map)

Real-time driver position: Firestore `onSnapshot` listener per visible trip.
At 50,000 drivers the dispatcher UI must paginate — show only the 200 nearest
drivers using a geohash range query.

---

## 6. Offline Strategy

### Write-first design

Every location point is written to Hive **before** any upload is attempted.
The upload never blocks location capture.

```
Location fix → accuracy gate → Hive queue → (async) upload → delete on ACK
```

If the network is unavailable:

- Points accumulate in Hive (`locationQueue` LazyBox).
- `UploadWorker` polls on a configurable interval and uploads when `isConnected`.
- `ConnectivityService.onConnectivityChanged` triggers an immediate drain on
  reconnect.
- On trip end, `stopTracking()` forces a final upload attempt before archiving.

### Hive capacity

`LocationEntry` is ~200 bytes. At 12 points/minute, 8 hours offline =
5,760 points = ~1.15 MB. Hive handles this trivially. The retention policy
(`uploadedRecordRetentionDays: 7`) prunes confirmed records after 7 days.

### Data integrity

- Each `LocationEntry` has a UUID that serves as the idempotency key on
  Firestore (document ID). Re-uploading a point after a partial ACK writes
  the same document — safe.
- `retryCount` is incremented on failed uploads. Points exceeding
  `maxRetryCount: 5` are logged to the telemetry box and excluded from
  further upload attempts to prevent queue bloat.

---

## 7. Retry Strategy

`UploadWorker` uses a periodic timer with exponential back-off implemented
via the `retry` package in `LocationRemoteDatasource`:

```dart
await retry(
  () => _uploadBatch(locations),
  retryIf: (e) => e is DioException && _isRetryable(e),
  maxAttempts: AppConstants.maxRetryCount, // 5
);
```

Retryable conditions: network timeouts, 5xx responses, socket errors.
Non-retryable: 400 Bad Request, 401 Unauthorized (stops immediately).

Per-entry retry counts are persisted in Hive so they survive app restarts.

---

## 8. Synchronisation

### Conflict resolution

Firestore uses last-write-wins per document. Since each location point is its
own document (keyed by UUID), there are no conflicts between points.

The `trips/{tripId}` document is written once on start and once on end —
both from the same device, so concurrent writes from multiple devices are
not possible in the current single-driver-per-trip model.

### Ordering guarantee

Points are written to Firestore with a `timestamp` field (ISO 8601, device
clock). Server-side ordering by `timestamp` reconstructs the route.

Client clock skew is a known issue on long-running trips. The `sequenceNumber`
field on each `LocationEntry` provides a secondary ordering key that is
independent of wall clock time.

### Background → foreground consistency

`LocationRepositoryImpl.foregroundLocationStream` seeds from the plugin's
`getCurrentPosition()` when a listener subscribes, then forwards all
subsequent plugin events. The UI therefore shows the correct position
immediately on foreground without waiting for the next location event.

Trip restoration on app relaunch (`BootReceiver.checkAndRestoreIfNeeded()`)
re-subscribes to the plugin stream and emits the latest Hive location to
the UI stream via `_emitLatestSavedLocation()`, ensuring no visual jump.