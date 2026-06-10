import 'hive_storage.dart';

class DriverProfile {
  final String id;
  final String name;
  final String grade; // e.g. "Gold", "Silver", "Bronze"
  final String avatarInitial;
  final String countryCode;

  DriverProfile({
    required this.id,
    required this.name,
    required this.grade,
    required this.countryCode,
  }) : avatarInitial = name.isEmpty ? '?' : name;

  String get initial => name.isEmpty ? '?' : name[0].toUpperCase();

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'grade': grade,
        'countryCode': countryCode,
      };

  factory DriverProfile.fromMap(Map<String, dynamic> map) => DriverProfile(
        id: map['id'] as String? ?? '',
        name: map['name'] as String? ?? 'Driver',
        grade: map['grade'] as String? ?? 'Standard',
        countryCode: map['countryCode'] as String? ?? 'PK',
      );

  static DriverProfile placeholder = DriverProfile(
    id: 'local',
    name: 'Driver',
    grade: 'Standard',
    countryCode: 'PK',
  );
}

class DriverProfileService {
  static const _key = 'driver_profile';

  Future<DriverProfile> getProfile() async {
    final box = HiveStorage.config;
    final raw = box.get(_key);
    if (raw == null) return DriverProfile.placeholder;
    return DriverProfile.fromMap(Map<String, dynamic>.from(raw as Map));
  }

  Future<void> saveProfile(DriverProfile profile) async {
    await HiveStorage.config.put(_key, profile.toMap());
  }

  /// Seeds a default profile if none exists (called at app start).
  Future<DriverProfile> getOrCreate() async {
    final existing = await getProfile();
    if (existing.id != DriverProfile.placeholder.id) return existing;
    final defaultProfile = DriverProfile(
      id: 'driver_${DateTime.now().millisecondsSinceEpoch}',
      name: 'Driver',
      grade: 'Standard',
      countryCode: 'PK',
    );
    await saveProfile(defaultProfile);
    return defaultProfile;
  }
}
