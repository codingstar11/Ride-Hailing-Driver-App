import 'package:equatable/equatable.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class MapLocation extends Equatable {
  final double latitude;
  final double longitude;
  final double heading;
  final double accuracy;
  final DateTime timestamp;

  const MapLocation({
    required this.latitude,
    required this.longitude,
    required this.heading,
    required this.accuracy,
    required this.timestamp,
  });

  LatLng get latLng => LatLng(latitude, longitude);

  @override
  List<Object?> get props => [latitude, longitude, heading, accuracy, timestamp];
}
