import '../repositories/location_repository.dart';

class UploadPendingLocationsUseCase {
  final LocationRepository _repository;
  UploadPendingLocationsUseCase(this._repository);

  Future<int> call() => _repository.uploadPendingLocations();

  Stream<int> get pendingCount => _repository.pendingLocationCount;
}
