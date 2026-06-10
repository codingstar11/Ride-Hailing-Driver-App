import '../repositories/location_repository.dart';

class StopTrackingUseCase {
  final LocationRepository _repository;
  StopTrackingUseCase(this._repository);

  Future<void> call() => _repository.stopTracking();
}
