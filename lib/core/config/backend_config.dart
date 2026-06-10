enum BackendType {
  firebase,

  /// Simulated in-process backend for development / demo without Firebase.
  mock,
}

/// Change this one constant to flip the entire app between Firebase and Mock.
const BackendType activeBackend = BackendType.firebase;