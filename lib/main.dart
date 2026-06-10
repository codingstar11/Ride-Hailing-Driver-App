import 'package:flutter/material.dart';

import 'core/config/backend_config.dart';
import 'core/services/background_service_handler.dart';
import 'core/services/boot_receiver.dart';
import 'core/storage/hive_storage.dart';
import 'core/di/injection.dart';
import 'core/utils/app_logger.dart';
import 'app.dart';

import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  AppLogger.info('MAIN', '══════ Driver App Starting ══════');
  AppLogger.info('MAIN', 'Backend: ${activeBackend.name}');

  // 1. Open all Hive boxes.
  AppLogger.info('MAIN', 'Initialising Hive storage…');
  await HiveStorage.initialise();
  AppLogger.info('MAIN', 'Hive storage ready');

  // 2. Initialise Firebase if selected as the active backend.
  if (activeBackend == BackendType.firebase) {
    AppLogger.info('MAIN', 'Initialising Firebase…');
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    AppLogger.info('MAIN', 'Firebase ready');
  }

  // 3. Wire dependencies.
  AppLogger.info('MAIN', 'Configuring dependency injection…');
  await configureDependencies();
  AppLogger.info('MAIN', 'DI ready');

  // 4. Register background service.
  AppLogger.info('MAIN', 'Initialising background service…');
  await BackgroundServiceHandler.initialize();
  AppLogger.info('MAIN', 'Background service registered');

  // 5. Post-reboot / process-kill recovery.
  AppLogger.info('MAIN', 'Checking for post-reboot trip recovery…');
  final restored = await BootReceiver.checkAndRestoreIfNeeded();
  if (restored) {
    AppLogger.info('MAIN',
        'Trip restored after reboot/kill — background service restarted');
  } else {
    AppLogger.info('MAIN', 'No post-reboot recovery needed');
  }

  AppLogger.info('MAIN', 'Launching app');
  runApp(const DriverApp());
}