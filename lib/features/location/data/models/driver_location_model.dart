import '../../../../core/storage/location_entry.dart';
import '../../domain/entities/driver_location.dart';

/// Data-layer model that converts between GPS event maps, Hive entries,
/// and the domain [DriverLocation] entity.
class DriverLocationModel extends DriverLocation {
  const DriverLocationModel({
    required super.id,
    required super.latitude,
    required super.longitude,
    required super.accuracy,
    super.heading,
    super.speed,
    required super.timestamp,
  });

  /// Creates a model from a raw map emitted by the background service.
  factory DriverLocationModel.fromServiceMap(Map<String, dynamic> map) {
    return DriverLocationModel(
      id: map['id'] as String? ?? '',
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      accuracy: (map['accuracy'] as num).toDouble(),
      heading: map['heading'] != null ? (map['heading'] as num).toDouble() : null,
      speed: map['speed'] != null ? (map['speed'] as num).toDouble() : null,
      timestamp: DateTime.parse(map['timestamp'] as String),
    );
  }

  /// Creates a model from a Hive [LocationEntry].
  factory DriverLocationModel.fromHiveEntry(LocationEntry entry) {
    return DriverLocationModel(
      id: entry.uuid,
      latitude: entry.latitude,
      longitude: entry.longitude,
      accuracy: entry.accuracy,
      heading: entry.heading,
      speed: entry.speed,
      timestamp: entry.timestamp,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        if (heading != null) 'heading': heading,
        if (speed != null) 'speed': speed,
        'timestamp': timestamp.toIso8601String(),
      };
}
