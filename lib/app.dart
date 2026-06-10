import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'core/di/injection.dart';
import 'core/theme/app_theme.dart';
import 'features/location/presentation/bloc/location_bloc.dart';
import 'features/map/presentation/bloc/map_bloc.dart';
import 'features/map/presentation/pages/driver_map_page.dart';

class DriverApp extends StatelessWidget {
  const DriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (_) {
            final bloc = getIt<LocationBloc>();
            // On every app launch (including relaunches after being killed),
            // check Hive for a persisted active trip.  If found, the bloc
            // will call repository.resumeTracking() and emit LocationTracking
            // automatically — the driver never sees the "Start Trip" button.
            bloc.add(const TripRestorationRequested());
            return bloc;
          },
        ),
        BlocProvider(create: (_) => getIt<MapBloc>()..add(const MapInitialized())),
      ],
      child: MaterialApp(
        title: 'Driver Tracker',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: ThemeMode.dark,
        home: const DriverMapPage(),
      ),
    );
  }
}
