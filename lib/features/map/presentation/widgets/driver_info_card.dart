import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ride_hailing_driver/core/constants/app_constants.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/storage/driver_profile.dart';
import '../../../../core/theme/app_theme.dart';
import '../bloc/map_bloc.dart';

class DriverInfoCard extends StatefulWidget {
  const DriverInfoCard({super.key});

  @override
  State<DriverInfoCard> createState() => _DriverInfoCardState();
}

class _DriverInfoCardState extends State<DriverInfoCard> {
  DriverProfile? _profile;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final profile = await getIt<DriverProfileService>().getProfile();
    if (mounted) setState(() => _profile = profile);
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile ?? DriverProfile.placeholder;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          // Driver avatar
          Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [AppTheme.primaryColor, Color(0xFF007AFF)],
              ),
            ),
            child: Center(
              child: Text(
                profile.initial,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                BlocBuilder<MapBloc, MapState>(
                  builder: (context, state) {
                    String locationText = '${AppConstants.initialLatitude}, ${AppConstants.initialLongitude}';
                    if (state is MapLoaded && state.currentLocation != null) {
                      final loc = state.currentLocation!;
                      locationText =
                          '${loc.latitude.toStringAsFixed(5)}, ${loc.longitude.toStringAsFixed(5)}';
                    }
                    return Text(
                      locationText,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                        fontSize: 12,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          // Route points count + grade badge
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              BlocBuilder<MapBloc, MapState>(
                builder: (context, state) {
                  final points = state is MapLoaded ? state.routePoints.length : 0;
                  return Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryColor.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: AppTheme.primaryColor.withOpacity(0.3),
                      ),
                    ),
                    child: Column(
                      children: [
                        Text(
                          '$points',
                          style: const TextStyle(
                            color: AppTheme.primaryColor,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          'pts',
                          style: TextStyle(
                            color: AppTheme.primaryColor.withOpacity(0.7),
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 2),
              Text(
                profile.grade,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.4),
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
