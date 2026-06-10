import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../../../core/config/country_config.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/network/connectivity_service.dart';
import '../../../../core/services/device_vendor_service.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../location/presentation/bloc/location_bloc.dart';
import '../../../location/presentation/widgets/location_access_dialog.dart';
import '../../../location/presentation/widgets/xiaomi_guidance_dialog.dart';
import '../bloc/map_bloc.dart';
import '../widgets/tracking_status_panel.dart';
import '../widgets/driver_info_card.dart';
import '../widgets/map_provider_widget.dart';
import '../../../../core/services/permission_service.dart';

class DriverMapPage extends StatefulWidget {
  /// The active [CountryConfig] determines which map provider is rendered.
  final CountryConfig countryConfig;

  const DriverMapPage({
    super.key,
    this.countryConfig = CountryConfig.pk,
  });

  @override
  State<DriverMapPage> createState() => _DriverMapPageState();
}

class _DriverMapPageState extends State<DriverMapPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const _initialPosition = CameraPosition(
    target: LatLng(AppConstants.initialLatitude, AppConstants.initialLongitude),
    zoom: 15,
  );

  bool _isWaitingForPermission = false;
  bool _xiaomiGuidanceShown = false;
  GoogleMapController? _mapController;
  bool _userPanning = false;
  Timer? _panResetTimer;

  String get _currentTripId {
    final state = context.read<LocationBloc>().state;
    if (state is LocationTracking) return state.tripId;
    final now = DateTime.now();
    return 'TRIP_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.millisecondsSinceEpoch ~/ 1000}';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await DeviceVendorService.init();
      await _initialPermissionCheck();
    });
  }

  Future<void> _initialPermissionCheck() async {
    final status = await PermissionService.check();
    if (status == PermissionResult.granted ||
        status == PermissionResult.foregroundOnly) {
      AppLogger.info('UI', 'Location permission already granted at launch');
    }
  }

  @override
  void dispose() {
    _panResetTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        AppLogger.appResumed();
        AppLogger.appReturnedToForeground();
        _checkIfPermissionGrantedAfterReturn();
        if (mounted) {
          context.read<MapBloc>().add(const MapCameraSnapRequested());
        }
        break;
      case AppLifecycleState.paused:
        AppLogger.appPaused();
        AppLogger.appInBackground();
        break;
      case AppLifecycleState.detached:
        AppLogger.appDetached();
        break;
      case AppLifecycleState.inactive:
        AppLogger.appInactive();
        break;
      case AppLifecycleState.hidden:
        break;
    }
  }

  void _handlePermissionError(
    BuildContext context,
    LocationPermissionError state,
  ) {
    switch (state.type) {
      case PermissionErrorType.serviceDisabled:
        _showDialog(
          context,
          title: 'GPS Disabled',
          message: state.message,
          primaryLabel: 'Enable GPS',
          onPrimary: () async {
            Navigator.pop(context);
            await PermissionService.openLocationSettings();
          },
        );
        break;

      case PermissionErrorType.denied:
      case PermissionErrorType.backgroundRequired:
        _isWaitingForPermission = true;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => LocationAccessDialog(
            onConfirm: () async {
              Navigator.pop(context);
              await PermissionService.openAppSettings();
            },
          ),
        );
        break;

      case PermissionErrorType.permanentlyDenied:
        _isWaitingForPermission = true;
        _showDialog(
          context,
          title: 'Permission Required',
          message: state.message,
          primaryLabel: 'Open App Settings',
          onPrimary: () async {
            Navigator.pop(context);
            await PermissionService.openAppSettings();
          },
        );
        break;
    }
  }

  void _showDialog(
    BuildContext context, {
    required String title,
    required String message,
    required String primaryLabel,
    required VoidCallback onPrimary,
    String? secondaryLabel,
    VoidCallback? onSecondary,
  }) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surfaceColor,
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Text(message,
            style: TextStyle(color: Colors.white.withOpacity(0.8))),
        actions: [
          if (secondaryLabel != null)
            TextButton(
              onPressed: onSecondary,
              child: Text(secondaryLabel,
                  style: TextStyle(color: Colors.white.withOpacity(0.5))),
            ),
          ElevatedButton(
            onPressed: onPrimary,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryColor,
            ),
            child: Text(primaryLabel),
          ),
        ],
      ),
    );
  }

  Future<void> _checkIfPermissionGrantedAfterReturn() async {
    if (!_isWaitingForPermission) return;
    if (!mounted) return;

    final currentState = context.read<LocationBloc>().state;
    if (currentState is LocationTracking) {
      _isWaitingForPermission = false;
      return;
    }

    final status = await PermissionService.check();
    if (status == PermissionResult.granted ||
        status == PermissionResult.foregroundOnly) {
      _isWaitingForPermission = false;
      AppLogger.info(
          'UI', 'Permission granted after app resumption — starting trip');
      if (mounted) {
        context
            .read<LocationBloc>()
            .add(LocationTrackingStarted(_currentTripId));
      }
    } else {
      AppLogger.warn(
          'UI', 'Permission still missing after return — not starting trip');
    }
  }

  void _maybeShowXiaomiGuidance(BuildContext context) {
    if (!Platform.isAndroid) return;
    if (_xiaomiGuidanceShown) return;
    if (!DeviceVendorService.isXiaomi) return;

    _xiaomiGuidanceShown = true;
    showDialog(
      context: context,
      builder: (_) => XiaomiGuidanceDialog(
        onDismiss: () => Navigator.pop(context),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      body: MultiBlocListener(
        listeners: [
          BlocListener<LocationBloc, LocationState>(
            listener: (context, state) {
              if (state is LocationPermissionError) {
                _handlePermissionError(context, state);
              }
              if (state is LocationTracking) {
                _maybeShowXiaomiGuidance(context);
                context.read<MapBloc>().add(const MapTrackingStarted());
                context.read<MapBloc>().add(const MapCameraSnapRequested());
              }
            },
          ),
          
          BlocListener<MapBloc, MapState>(
            listenWhen: (previous, current) {
              if (previous is MapLoaded && current is MapLoaded) {
                final prevLoc = previous.currentLocation;
                final currLoc = current.currentLocation;
                if (prevLoc == null || currLoc == null) return currLoc != null;
                return prevLoc.latitude != currLoc.latitude ||
                    prevLoc.longitude != currLoc.longitude;
              }
              return current is MapLoaded && current.currentLocation != null;
            },
            listener: (context, state) {
              if (state is MapLoaded &&
                  state.currentLocation != null &&
                  _mapController != null &&
                  !_userPanning) {
                final target = state.currentLocation!.latLng;
                _mapController!.animateCamera(
                  CameraUpdate.newCameraPosition(
                    CameraPosition(
                      target: target,
                      zoom: 16,
                      bearing: state.currentLocation!.heading,
                    ),
                  ),
                );
              }
            },
          ),
        ],
        child: Stack(
          children: [
            _buildMap(),
            _buildTopGradient(),
            _buildTopBar(),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _buildBottomPanel(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMap() {
    return BlocBuilder<MapBloc, MapState>(
      builder: (context, state) {
        Set<Marker> markers = {};
        Set<Polyline> polylines = {};
        Set<Circle> circles = {};

        if (state is MapLoaded && state.currentLocation != null) {
          final pos =
              state.interpolatedPosition ?? state.currentLocation!.latLng;
          final heading = state.currentLocation!.heading;

          markers.add(
            Marker(
              markerId: const MarkerId('driver'),
              position: pos,
              rotation: heading,
              anchor: const Offset(0.5, 0.5),
              flat: true,
              infoWindow: InfoWindow(
                title: 'Driver Position',
                snippet:
                    'Accuracy: ${state.currentLocation!.accuracy.toStringAsFixed(1)}m',
              ),
            ),
          );

          circles.add(
            Circle(
              circleId: const CircleId('accuracy'),
              center: pos,
              radius: state.currentLocation!.accuracy,
              fillColor: AppTheme.primaryColor.withOpacity(0.15),
              strokeColor: AppTheme.primaryColor.withOpacity(0.5),
              strokeWidth: 1,
            ),
          );

          if (state.routePoints.length > 1) {
            polylines.add(
              Polyline(
                polylineId: const PolylineId('route'),
                points: state.routePoints,
                color: AppTheme.primaryColor,
                width: 4,
              ),
            );
          }
        }

        // Route through MapProviderWidget so runtime provider
        // selection based on CountryConfig.mapProvider is honoured.
        return MapProviderWidget(
          provider: widget.countryConfig.mapProvider,
          initialCameraPosition: _initialPosition,
          markers: markers,
          polylines: polylines,
          circles: circles,
          onMapCreated: (controller) {
            _mapController = controller;
            context.read<MapBloc>().add(MapControllerReady(controller));
          },
          onCameraMoveStarted: () {
            _userPanning = true;
            _panResetTimer?.cancel();
            _panResetTimer = Timer(const Duration(seconds: 5), () {
              if (mounted) setState(() => _userPanning = false);
            });
          },
        );
      },
    );
  }

  Widget _buildTopGradient() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: 120,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppTheme.backgroundDark.withOpacity(0.9),
              Colors.transparent,
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceColor.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppTheme.primaryColor.withOpacity(0.3),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: AppTheme.primaryColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'DRIVER',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              BlocBuilder<LocationBloc, LocationState>(
                builder: (context, state) {
                  if (state is! LocationTracking) {
                    return const _ConnectivityDot(isOnline: false);
                  }
                  // Read live connectivity from the service via DI.
                  final isConnected = getIt<ConnectivityService>().isConnected;
                  return _ConnectivityDot(isOnline: isConnected);
                },
              ),
            ],
          ),
        ).animate().fadeIn(duration: 400.ms).slideY(begin: -0.5),
      ),
    );
  }

  Widget _buildBottomPanel() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.4),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          const DriverInfoCard(),
          const SizedBox(height: 12),
          const TrackingStatusPanel(),
          const SizedBox(height: 12),
          _buildActionButtons(),
          const SizedBox(height: 24),
        ],
      ),
    )
        .animate()
        .slideY(begin: 1.0, duration: 500.ms, curve: Curves.easeOutCubic);
  }

  Widget _buildActionButtons() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: BlocBuilder<LocationBloc, LocationState>(
        builder: (context, state) {
          final isTracking = state is LocationTracking;
          final isChecking = state is LocationPermissionChecking;

          return Row(
            children: [
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  child: ElevatedButton.icon(
                    onPressed: isChecking
                        ? null
                        : () {
                            if (isTracking) {
                              context
                                  .read<LocationBloc>()
                                  .add(const LocationTrackingStopped());
                            } else {
                              context.read<LocationBloc>().add(
                                    LocationTrackingStarted(_currentTripId),
                                  );
                            }
                          },
                    icon: isChecking
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(
                            isTracking
                                ? Icons.stop_rounded
                                : Icons.play_arrow_rounded,
                            size: 20,
                          ),
                    label: Text(
                      isChecking
                          ? 'Checking permissions…'
                          : isTracking
                              ? 'Stop Trip'
                              : 'Start Trip',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isTracking
                          ? AppTheme.errorColor
                          : AppTheme.primaryColor,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                decoration: BoxDecoration(
                  color: AppTheme.cardDark,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                ),
                child: IconButton(
                  onPressed: isTracking
                      ? () => context
                          .read<LocationBloc>()
                          .add(const LocationUploadRequested())
                      : null,
                  icon: const Icon(Icons.cloud_upload_outlined),
                  color: isTracking
                      ? AppTheme.primaryColor
                      : Colors.white.withOpacity(0.3),
                  iconSize: 22,
                  padding: const EdgeInsets.all(14),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ConnectivityDot extends StatelessWidget {
  final bool isOnline;
  const _ConnectivityDot({required this.isOnline});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor.withOpacity(0.9),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: (isOnline ? AppTheme.successColor : AppTheme.errorColor)
              .withOpacity(0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: isOnline ? AppTheme.successColor : AppTheme.errorColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            isOnline ? 'LIVE' : 'OFFLINE',
            style: TextStyle(
              color: isOnline ? AppTheme.successColor : AppTheme.errorColor,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}