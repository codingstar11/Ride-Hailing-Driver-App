import '../../domain/entities/map_location.dart';
import '../../domain/repositories/map_repository.dart';
import '../datasources/map_location_datasource.dart';

class MapRepositoryImpl implements MapRepository {
  final MapLocationDatasource _datasource;
  MapRepositoryImpl(this._datasource);

  @override
  Stream<MapLocation> getDriverLocationStream() =>
      _datasource.getDriverLocationStream();
}
