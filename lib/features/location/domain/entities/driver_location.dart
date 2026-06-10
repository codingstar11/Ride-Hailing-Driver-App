import 'package:equatable/equatable.dart';

class DriverLocation extends Equatable {
  final String id;
  final double latitude;
  final double longitude;
  final double accuracy;
  final double? heading;
  final double? speed;
  final DateTime timestamp;

  const DriverLocation({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    this.heading,
    this.speed,
    required this.timestamp,
  });

  bool get isAccurate => accuracy <= 50.0;

  @override
  List<Object?> get props => [
        id,
        latitude,
        longitude,
        accuracy,
        heading,
        speed,
        timestamp,
      ];

  @override
  String toString() =>
      'DriverLocation(lat: $latitude, lng: $longitude, acc: ${accuracy}m, t: $timestamp)';
}
