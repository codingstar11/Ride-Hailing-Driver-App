import 'package:logger/logger.dart';

import '../storage/hive_storage.dart';

/// Enumeration of supported map providers.
enum MapProvider { google, mapbox, here }

/// Enumeration of supported payment providers.
enum PaymentProvider { stripe, hyperPay, paytm, jazzCash, cash }

class CountryConfig {
  final String countryCode;
  final MapProvider mapProvider;
  final List<PaymentProvider> paymentProviders;
  final List<String> enabledFeatures;
  final String currencyCode;
  final String distanceUnit; // 'km' or 'miles'
  final double locationIntervalSeconds;
  final double minAccuracyMeters;
  final double locationDistanceMeters;
  final bool requiresNationalId;

  const CountryConfig({
    required this.countryCode,
    required this.mapProvider,
    required this.paymentProviders,
    required this.enabledFeatures,
    required this.currencyCode,
    required this.distanceUnit,
    required this.locationIntervalSeconds,
    required this.minAccuracyMeters,
    this.locationDistanceMeters = 20.0,
    required this.requiresNationalId,
  });

  // ── Default configs bundled offline ────────────────────────────────────

  static const CountryConfig pk = CountryConfig(
    countryCode: 'PK',
    mapProvider: MapProvider.google,
    paymentProviders: [PaymentProvider.jazzCash, PaymentProvider.cash],
    enabledFeatures: ['cash_payment', 'scheduled_rides'],
    currencyCode: 'PKR',
    distanceUnit: 'km',
    locationIntervalSeconds: 5,
    minAccuracyMeters: 50,
    requiresNationalId: false,
  );

  static const CountryConfig ae = CountryConfig(
    countryCode: 'AE',
    mapProvider: MapProvider.here,
    paymentProviders: [PaymentProvider.hyperPay, PaymentProvider.stripe],
    enabledFeatures: ['card_payment', 'corporate_billing'],
    currencyCode: 'AED',
    distanceUnit: 'km',
    locationIntervalSeconds: 3,
    minAccuracyMeters: 30,
    requiresNationalId: true,
  );

  static const CountryConfig gb = CountryConfig(
    countryCode: 'GB',
    mapProvider: MapProvider.google,
    paymentProviders: [PaymentProvider.stripe],
    enabledFeatures: ['card_payment', 'scheduled_rides', 'corporate_billing'],
    currencyCode: 'GBP',
    distanceUnit: 'miles',
    locationIntervalSeconds: 5,
    minAccuracyMeters: 50,
    requiresNationalId: false,
  );

  bool isFeatureEnabled(String feature) => enabledFeatures.contains(feature);

  // ── Hive serialisation ─────────────────────────────────────────────────

  Map<String, dynamic> toMap() => {
        'countryCode': countryCode,
        'mapProvider': mapProvider.name,
        'paymentProviders': paymentProviders.map((p) => p.name).toList(),
        'enabledFeatures': enabledFeatures,
        'currencyCode': currencyCode,
        'distanceUnit': distanceUnit,
        'locationIntervalSeconds': locationIntervalSeconds,
        'locationDistanceMeters': locationDistanceMeters,
        'minAccuracyMeters': minAccuracyMeters,
        'requiresNationalId': requiresNationalId,
      };

  factory CountryConfig.fromMap(Map<String, dynamic> map) => CountryConfig(
        countryCode: map['countryCode'] as String,
        mapProvider: MapProvider.values.byName(map['mapProvider'] as String),
        paymentProviders: (map['paymentProviders'] as List)
            .map((p) => PaymentProvider.values.byName(p as String))
            .toList(),
        enabledFeatures: List<String>.from(map['enabledFeatures'] as List),
        currencyCode: map['currencyCode'] as String,
        distanceUnit: map['distanceUnit'] as String,
        locationIntervalSeconds: (map['locationIntervalSeconds'] as num).toDouble(),
        locationDistanceMeters: (map['locationDistanceMeters'] as num?)?.toDouble() ?? 20.0,
        minAccuracyMeters: (map['minAccuracyMeters'] as num).toDouble(),
        requiresNationalId: map['requiresNationalId'] as bool,
      );
}

/// Repository-level service for reading and caching country configs via Hive.
class ConfigService {
  static final _logger = Logger();

  static const String _activeConfigKey = 'active_country_config';

  Future<CountryConfig> getConfig(String countryCode) async {
    final box = HiveStorage.config;

    // Try cached version first (works offline).
    final cached = box.get(_activeConfigKey);
    if (cached != null && (cached as Map)['countryCode'] == countryCode) {
      _logger.d('[ConfigService] Returning cached config for $countryCode');
      return CountryConfig.fromMap(Map<String, dynamic>.from(cached));
    }

    // Fall back to bundled defaults.
    final config = _bundledDefaults[countryCode] ?? CountryConfig.pk;
    await box.put(_activeConfigKey, config.toMap());
    _logger.i('[ConfigService] Loaded bundled default config for $countryCode');
    return config;
  }

  Future<void> cacheConfig(CountryConfig config) async {
    await HiveStorage.config.put(_activeConfigKey, config.toMap());
    _logger.i('[ConfigService] Cached remote config for ${config.countryCode}');
  }

  static const _bundledDefaults = {
    'PK': CountryConfig.pk,
    'AE': CountryConfig.ae,
    'GB': CountryConfig.gb,
  };
}
