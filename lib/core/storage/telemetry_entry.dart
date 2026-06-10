import 'package:hive/hive.dart';

/// Hive model for a structured diagnostic event.
///
/// Written to the 'telemetry' LazyBox throughout the tracking lifecycle.
/// Used to diagnose:
///  • Scenario A — Xiaomi service kill: look for heartbeat timestamp gaps > 15min
///  • Scenario B — Missing route points: look for sequence number gaps and
///    upload_failed events during the affected trip
///
/// The LazyBox is chosen so the full log is only loaded from disk on demand
/// (e.g., when exporting a bug report via the debug screen or adb pull).
class TelemetryEntry extends HiveObject {
  final String event;    // machine-readable event name, e.g. 'location_saved'
  final String tripId;   // which trip this event belongs to
  final String payload;  // JSON-encoded Map<String, dynamic> with context
  final DateTime timestamp;

  TelemetryEntry({
    required this.event,
    required this.tripId,
    required this.payload,
    required this.timestamp,
  });

  @override
  String toString() =>
      'TelemetryEntry(event: $event, trip: $tripId, t: $timestamp)';
}

/// Hand-written TypeAdapter for [TelemetryEntry].
class TelemetryEntryAdapter extends TypeAdapter<TelemetryEntry> {
  static const int adapterTypeId = 1;

  @override
  final int typeId = adapterTypeId;

  @override
  TelemetryEntry read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return TelemetryEntry(
      event: fields[0] as String,
      tripId: fields[1] as String,
      payload: fields[2] as String,
      timestamp: fields[3] as DateTime,
    );
  }

  @override
  void write(BinaryWriter writer, TelemetryEntry obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.event)
      ..writeByte(1)
      ..write(obj.tripId)
      ..writeByte(2)
      ..write(obj.payload)
      ..writeByte(3)
      ..write(obj.timestamp);
  }
}
