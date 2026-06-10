abstract class Failure {
  final String message;
  const Failure(this.message);
}

class NetworkFailure extends Failure {
  const NetworkFailure(super.message);
}

class DatabaseFailure extends Failure {
  const DatabaseFailure(super.message);
}

class LocationFailure extends Failure {
  const LocationFailure(super.message);
}

class PermissionFailure extends Failure {
  const PermissionFailure(super.message);
}

class ServerFailure extends Failure {
  final int? statusCode;
  const ServerFailure(super.message, {this.statusCode});
}
