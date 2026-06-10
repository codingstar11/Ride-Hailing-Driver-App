import 'package:hive/hive.dart';

/// Hive model for a single GPS location stored in the offline queue.
///
/// Each entry is written to the 'location_queue' LazyBox immediately when
/// a GPS reading passes the accuracy filter. The entry remains in the box
/// until the server confirms receipt (Mock API ACK/Firebase), at which point it is
/// deleted — not marked uploaded — to keep the box lean.
///
/// Recovery after restart: on [LocationRepositoryImpl.startTracking], the
/// repository scans all box keys and re-attempts upload for any entries that
/// survived the previous session.
///
/// TypeAdapter: hand-written in [LocationEntryAdapter] below.
/// Field IDs must never change once data exists on device — only new IDs
/// can be added (additive schema evolution).
class LocationEntry extends HiveObject {

  final String uuid;
  final double latitude;
  final double longitude;
  final double accuracy;
  final double? heading;
  final double? speed;
  final DateTime timestamp;
  int retryCount;
  final String tripId;

  LocationEntry({
    required this.uuid,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    this.heading,
    this.speed,
    required this.timestamp,
    required this.tripId,
    this.retryCount = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': uuid,
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        if (heading != null) 'heading': heading,
        if (speed != null) 'speed': speed,
        'timestamp': timestamp.toIso8601String(),
      };

  @override
  String toString() =>
      'LocationEntry(uuid: $uuid, lat: $latitude, lng: $longitude, acc: ${accuracy}m, retries: $retryCount)';
}
class LocationEntryAdapter extends TypeAdapter<LocationEntry> {
  static const int adapterTypeId = 0;

  @override
  final int typeId = adapterTypeId;

  @override
  LocationEntry read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return LocationEntry(
      uuid: fields[0] as String,
      latitude: fields[1] as double,
      longitude: fields[2] as double,
      accuracy: fields[3] as double,
      heading: fields[4] as double?,
      speed: fields[5] as double?,
      timestamp: fields[6] as DateTime,
      retryCount: fields[7] as int,
      tripId: fields[8] as String,
    );
  }

  @override
  void write(BinaryWriter writer, LocationEntry obj) {
    writer
      ..writeByte(9) // field count
      ..writeByte(0)
      ..write(obj.uuid)
      ..writeByte(1)
      ..write(obj.latitude)
      ..writeByte(2)
      ..write(obj.longitude)
      ..writeByte(3)
      ..write(obj.accuracy)
      ..writeByte(4)
      ..write(obj.heading)
      ..writeByte(5)
      ..write(obj.speed)
      ..writeByte(6)
      ..write(obj.timestamp)
      ..writeByte(7)
      ..write(obj.retryCount)
      ..writeByte(8)
      ..write(obj.tripId);
  }
}
