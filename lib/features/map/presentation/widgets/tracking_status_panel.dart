import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../location/presentation/bloc/location_bloc.dart';
import '../../../map/presentation/bloc/map_bloc.dart';

class TrackingStatusPanel extends StatelessWidget {
  const TrackingStatusPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: BlocBuilder<LocationBloc, LocationState>(
        builder: (context, locationState) {
          return BlocBuilder<MapBloc, MapState>(
            builder: (context, mapState) {
              final isTracking = locationState is LocationTracking;
              final pendingCount = locationState is LocationTracking
                  ? locationState.pendingCount
                  : 0;
              final isUploading = locationState is LocationTracking
                  ? locationState.isUploading
                  : false;

              double? accuracy;
              double? heading;
              if (mapState is MapLoaded && mapState.currentLocation != null) {
                accuracy = mapState.currentLocation!.accuracy;
                heading = mapState.currentLocation!.heading;
              }

              return Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.cardDark,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.06),
                  ),
                ),
                child: Row(
                  children: [
                    _StatusItem(
                      icon: Icons.gps_fixed,
                      label: 'Accuracy',
                      value: accuracy != null
                          ? '${accuracy.toStringAsFixed(0)}m'
                          : '--',
                      color: accuracy != null && accuracy < 20
                          ? AppTheme.successColor
                          : AppTheme.warningColor,
                    ),
                    _Divider(),
                    _StatusItem(
                      icon: Icons.explore_outlined,
                      label: 'Heading',
                      value: heading != null
                          ? '${heading.toStringAsFixed(0)}°'
                          : '--',
                      color: Colors.white,
                    ),
                    _Divider(),
                    _StatusItem(
                      icon: isUploading
                          ? Icons.cloud_sync
                          : Icons.cloud_outlined,
                      label: 'Pending',
                      value: pendingCount.toString(),
                      color: pendingCount > 0
                          ? AppTheme.warningColor
                          : AppTheme.successColor,
                      animate: isUploading,
                    ),
                    _Divider(),
                    _StatusItem(
                      icon: isTracking
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      label: 'Status',
                      value: isTracking ? 'LIVE' : 'IDLE',
                      color: isTracking
                          ? AppTheme.successColor
                          : Colors.white.withOpacity(0.4),
                      animate: isTracking,
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _StatusItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final bool animate;

  const _StatusItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.animate = false,
  });

  @override
  Widget build(BuildContext context) {
    Widget iconWidget = Icon(icon, size: 18, color: color);
    if (animate) {
      iconWidget = iconWidget
          .animate(onPlay: (c) => c.repeat())
          .fadeIn(duration: 800.ms)
          .then()
          .fadeOut(duration: 800.ms);
    }

    return Expanded(
      child: Column(
        children: [
          iconWidget,
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.4),
              fontSize: 10,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 36,
      color: Colors.white.withOpacity(0.08),
    );
  }
}
