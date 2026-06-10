import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:logger/logger.dart';

/// Detects Xiaomi/MIUI devices and provides guidance for battery optimization.
class DeviceVendorService {
  static final _logger = Logger();
  static AndroidDeviceInfo? _androidInfo;
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    if (!Platform.isAndroid) return;
    try {
      _androidInfo = await DeviceInfoPlugin().androidInfo;
      _logger.i('[DeviceVendor] manufacturer=${_androidInfo?.manufacturer}  '
          'brand=${_androidInfo?.brand}  model=${_androidInfo?.model}');
    } catch (e) {
      _logger.w('[DeviceVendor] Failed to read device info: $e');
    }
  }

  static bool get isXiaomi {
    final info = _androidInfo;
    if (info == null) return false;
    final m = info.manufacturer.toLowerCase();
    final b = info.brand.toLowerCase();
    return m == 'xiaomi' || m == 'redmi' || m == 'poco' ||
        b == 'xiaomi' || b == 'redmi' || b == 'poco';
  }

  static bool get isMiui => isXiaomi;

  static String get manufacturer =>
      _androidInfo?.manufacturer ?? 'Unknown';

  static String get model => _androidInfo?.model ?? 'Unknown';

  static int get sdkInt => _androidInfo?.version.sdkInt ?? 0;
}
