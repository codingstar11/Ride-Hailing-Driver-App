import 'package:get_it/get_it.dart';

import '../config/backend_config.dart';
import '../firebase/firebase_api_client.dart';
import '../mock_api/mock_api_client.dart';
import '../network/connectivity_service.dart';
import '../storage/location_hive_datasource.dart';
import '../storage/driver_profile.dart';
import '../config/country_config.dart';
import '../../features/location/data/datasources/location_remote_datasource.dart';
import '../../features/location/data/repositories/location_repository_impl.dart';
import '../../features/location/domain/repositories/location_repository.dart';
import '../../features/location/domain/usecases/start_tracking_usecase.dart';
import '../../features/location/domain/usecases/stop_tracking_usecase.dart';
import '../../features/location/domain/usecases/upload_pending_locations_usecase.dart';
import '../../features/location/presentation/bloc/location_bloc.dart';
import '../../features/map/data/datasources/map_location_datasource.dart';
import '../../features/map/data/repositories/map_repository_impl.dart';
import '../../features/map/domain/repositories/map_repository.dart';
import '../../features/map/domain/usecases/get_driver_location_stream_usecase.dart';
import '../../features/map/presentation/bloc/map_bloc.dart';

final getIt = GetIt.instance;

Future<void> configureDependencies() async {
  // ── Backend selection ──────────────────────────────────────────────────
  final ApiClient apiClient = switch (activeBackend) {
    BackendType.firebase => FirebaseApiClient(),
    BackendType.mock => MockApiClient(),
  };
  getIt.registerSingleton<ApiClient>(apiClient);

  // ── Core ───────────────────────────────────────────────────────────────
  final connectivity = ConnectivityService();
  await connectivity.initialize();
  getIt.registerSingleton<ConnectivityService>(connectivity);

  final configService = ConfigService();
  getIt.registerSingleton<ConfigService>(configService);

  final profileService = DriverProfileService();
  getIt.registerSingleton<DriverProfileService>(profileService);
  await profileService.getOrCreate();

  // ── Location Feature ───────────────────────────────────────────────────
  getIt.registerSingleton<LocationHiveDatasource>(LocationHiveDatasource());

  getIt.registerSingleton<LocationRemoteDatasource>(
    LocationRemoteDatasource(getIt<ApiClient>()),
  );

  getIt.registerSingleton<LocationRepository>(
    LocationRepositoryImpl(
      localDatasource: getIt<LocationHiveDatasource>(),
      remoteDatasource: getIt<LocationRemoteDatasource>(),
      connectivityService: getIt<ConnectivityService>(),
      configService: getIt<ConfigService>(),
      profileService: getIt<DriverProfileService>(),
    ),
  );

  getIt.registerFactory<StartTrackingUseCase>(
    () => StartTrackingUseCase(getIt<LocationRepository>()),
  );
  getIt.registerFactory<StopTrackingUseCase>(
    () => StopTrackingUseCase(getIt<LocationRepository>()),
  );
  getIt.registerFactory<UploadPendingLocationsUseCase>(
    () => UploadPendingLocationsUseCase(getIt<LocationRepository>()),
  );

  getIt.registerFactory<LocationBloc>(
    () => LocationBloc(
      startTracking: getIt<StartTrackingUseCase>(),
      stopTracking: getIt<StopTrackingUseCase>(),
      uploadPending: getIt<UploadPendingLocationsUseCase>(),
      connectivityService: getIt<ConnectivityService>(),
      locationRepository: getIt<LocationRepository>(),
    ),
  );

  // ── Map Feature ────────────────────────────────────────────────────────
  getIt.registerSingleton<MapLocationDatasource>(MapLocationDatasource());
  getIt.registerSingleton<MapRepository>(
    MapRepositoryImpl(getIt<MapLocationDatasource>()),
  );
  getIt.registerFactory<GetDriverLocationStreamUseCase>(
    () => GetDriverLocationStreamUseCase(
      getIt<LocationRepository>(),
    ),
  );
  getIt.registerFactory<MapBloc>(
    () => MapBloc(getIt<GetDriverLocationStreamUseCase>()),
  );
}