import '../entities/map_location.dart';

abstract class MapRepository {
  Stream<MapLocation> getDriverLocationStream();
}
