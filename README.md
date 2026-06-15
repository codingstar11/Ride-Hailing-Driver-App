# Ride Hailing Driver App

Production-grade Flutter driver app with continuous background location tracking,
Hive offline queue, Firebase backend, and BLoC-driven architecture.

---

## Architecture Overview

```
Presentation (BLoC)
    └─ UseCases
        └─ LocationRepository
            ├─ BackgroundServiceHandler  ← flutter_background_geolocation
            ├─ LocationHiveDatasource    ← Hive offline queue
            └─ LocationRemoteDatasource  ← Firebase / Mock API
```

**Layers**

- **Presentation** — `flutter_bloc`, `MapBloc`, `LocationBloc`
- **Domain** — use-cases, repository interfaces, entities
- **Data** — repository implementations, local (Hive) and remote datasources
- **Core** — DI (`get_it`), config, services, storage, utils

---

## Location Tracking

**Plugin:** `flutter_background_geolocation ^5.2.1` (Transistor Software)

Replaces the old `geolocator` + `flutter_background_service` stack.

| Scenario | Works |
|---|---|
| Foreground | ✅ |
| Background / minimised | ✅ |
| Screen locked | ✅ |
| App removed from recents | ✅ (stopOnTerminate: false) |
| Device reboot | ✅ (startOnBoot: true) |
| Long-running trips | ✅ |

**Update triggers (whichever fires first)**

- Every **5 seconds** (heartbeatInterval)
- Every **20 metres** (distanceFilter)

Both values are applied via `BackgroundServiceHandler.applyCountryConfig()` at
trip start and can be updated at runtime per `CountryConfig`.

### Motion Detection & Battery Optimisation

The plugin uses the device's native activity recognition (Google Play Services
on Android, Core Motion on iOS) to detect stationary periods. When the driver
is stationary the plugin reduces sampling frequency automatically.

| Feature | Config key |
|---|---|
| Motion / stationary detection | `stopOnStationary: false` (we manage stops) |
| Activity recognition interval | `activityRecognitionInterval: 10000` ms |
| Min confidence for activity | `minimumActivityRecognitionConfidence: 75` |
| Stop timeout | `stopTimeout: 5` minutes |
| Foreground service | `foregroundService: true` |
| Headless mode (app removed) | `enableHeadless: true` |

Battery optimisation on Android is handled by:

1. `permission_handler` requesting `ignoreBatteryOptimizations` at permission
   setup time (`PermissionService.request()`).
2. `activityRecognition` permission for the native motion API.
3. Xiaomi / MIUI-specific guidance shown via `XiaomiGuidanceDialog` — the
   plugin covers standard Android battery optimisation; MIUI's custom
   AutoStart restriction still requires a manual user action that the dialog
   explains.

---

## Data Flow

```
flutter_background_geolocation
    ↓ onLocation callback
BackgroundServiceHandler._onLocation()
    ↓ broadcast stream (accuracy-gated)
LocationRepositoryImpl._onLocationReceived()
    ↓
LocationHiveDatasource.saveLocation()   ← written to Hive queue first
    ↓ (if online & batch ≥ 1)
LocationRemoteDatasource.uploadLocationBatch()
    ↓ (on ACK)
LocationHiveDatasource.deleteConfirmed()
```

**UploadWorker** runs a periodic timer that drains the Hive queue when
connectivity is available, providing retry coverage independent of incoming
location events.

---

## Hive Storage

| Box | Type | Purpose |
|---|---|---|
| `locationQueue` | `LazyBox<LocationEntry>` | Offline upload queue |
| `activeTrip` | `Box<Map>` | Current trip ID |
| `completedTrips` | `LazyBox<Map>` | Archived trip summaries |
| `config` | `Box<dynamic>` | Cached `CountryConfig` |
| `telemetry` | `LazyBox<TelemetryEntry>` | Structured event log |

---

## CountryConfig

Bundled offline configs for PK, AE, GB. Selected per country code at trip
start. Applied to the plugin via `BackgroundGeolocation.setConfig()`.

| Country | Interval | Distance | Accuracy |
|---|---|---|---|
| PK | 5 s | 20 m | 50 m |
| AE | 3 s | 20 m | 30 m |
| GB | 5 s | 20 m | 50 m |

---

## Firebase Backend

`FirebaseApiClient` writes to Firestore:

- `trips/{tripId}` — start / end markers
- `trips/{tripId}/locations/{uuid}` — individual location points

Switch between Firebase and the mock API via `BackendType` in
`lib/core/config/backend_config.dart`.

---

## Android Setup

### 1. Add the plugin's maven repository

In `android/build.gradle.kts`:

```kotlin
allprojects {
    repositories {
        maven(url = "https://dl.cloudsmith.io/public/transistorsoft/background-geolocation/maven/")
        // ... other repos
    }
}
```

### 2. AndroidManifest.xml

The manifest already includes all required entries:

- `ACCESS_FINE_LOCATION`, `ACCESS_BACKGROUND_LOCATION`
- `ACTIVITY_RECOGNITION`
- `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION`
- `RECEIVE_BOOT_COMPLETED`
- `TrackingService` and `LocationRequestService` with `foregroundServiceType="location"`
- `TSDeviceBootReceiver` for auto-restart after reboot

No changes needed.

### 3. google-services.json

Place your `google-services.json` at `android/app/google-services.json`.

### 4. Proguard

Add to `android/app/proguard-rules.pro`:

```
-keep class com.transistorsoft.** { *; }
```

---

## iOS Setup

### 1. Podfile

Minimum iOS 13:

```ruby
platform :ios, '13.0'
```

Run:

```sh
cd ios && pod install
```

### 2. Info.plist

Already configured with:

- `NSLocationWhenInUseUsageDescription`
- `NSLocationAlwaysAndWhenInUseUsageDescription`
- `NSLocationAlwaysUsageDescription`
- `NSMotionUsageDescription`
- `UIBackgroundModes`: `location`, `fetch`, `processing`, `remote-notification`

### 3. AppDelegate.swift

No changes needed — the plugin auto-initialises via `FlutterBackgroundGeolocation`.

---

## Running the App

```sh
flutter pub get
flutter run
```

### Switching backends

In `lib/core/config/backend_config.dart`:

```dart
// Firebase (default)
const BackendType activeBackend = BackendType.firebase;

// Mock API (no Firebase needed)
const BackendType activeBackend = BackendType.mock;
```

---

## Running Tests

```sh
flutter test
```

Regenerate mocks after interface changes:

```sh
dart run build_runner build --delete-conflicting-outputs
```

**Test coverage**

| File | What it covers |
|---|---|
| `location_bloc_test.dart` | Permission results, tracking states, trip restoration |
| `map_bloc_test.dart` | Map initialization, route accumulation, marker interpolation |
| `upload_worker_test.dart` | Online/offline upload scheduling, retry logic |
| `location_queue_test.dart` | Hive queue CRUD, retry counts, batch limits |
| `restoration_test.dart` | Active trip persistence across app restarts |
| `gps_accuracy_filter_test.dart` | Accuracy gate — good vs noisy fixes |
| `connectivity_recovery_test.dart` | Queue drain on network reconnect |
| `mock_api_test.dart` | Mock API client responses |
| `location_repository_integration_test.dart` | Repository + datasource integration |

---

## Environment

- Flutter 3.x, Dart ≥ 3.0
- `flutter_background_geolocation ^5.2.1`
- Android minSdk 24, targetSdk 34
- iOS 13+