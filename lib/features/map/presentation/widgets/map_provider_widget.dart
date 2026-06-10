import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../../core/config/country_config.dart';
import '../../../../core/theme/app_theme.dart';

/// Factory widget that selects the correct map renderer based on
/// [CountryConfig.mapProvider] at runtime.

/// This widget corrects that by routing to the appropriate implementation:
///   • [MapProvider.google]  → [GoogleMap] (via google_maps_flutter)
///   • [MapProvider.mapbox] 
///   • [MapProvider.here]   
///
/// Adding a new provider only requires implementing [_buildHereMap] or
/// [_buildMapboxMap] and adding the corresponding package dependency.
class MapProviderWidget extends StatelessWidget {
  final MapProvider provider;
  final CameraPosition initialCameraPosition;
  final Set<Marker> markers;
  final Set<Polyline> polylines;
  final Set<Circle> circles;
  final void Function(GoogleMapController) onMapCreated;
  final VoidCallback onCameraMoveStarted;

  const MapProviderWidget({
    super.key,
    required this.provider,
    required this.initialCameraPosition,
    required this.markers,
    required this.polylines,
    required this.circles,
    required this.onMapCreated,
    required this.onCameraMoveStarted,
  });

  @override
  Widget build(BuildContext context) {
    switch (provider) {
      case MapProvider.google:
        return _buildGoogleMap();
      case MapProvider.here:
        return _buildUnsupportedProvider('HERE Maps');
      case MapProvider.mapbox:
        return _buildUnsupportedProvider('Mapbox');
    }
  }

  Widget _buildGoogleMap() {
    return GoogleMap(
      initialCameraPosition: initialCameraPosition,
      markers: markers,
      polylines: polylines,
      circles: circles,
      mapType: MapType.normal,
      myLocationEnabled: false,
      myLocationButtonEnabled: false,
      zoomControlsEnabled: false,
      compassEnabled: true,
      onMapCreated: onMapCreated,
      onCameraMoveStarted: onCameraMoveStarted,
    );
  }

  /// Placeholder rendered when a country config requests a provider whose
  /// native SDK is not yet bundled.  Shows a clear message instead of
  /// silently falling back to Google Maps (which would hide the misconfiguration).
  Widget _buildUnsupportedProvider(String name) {
    return Container(
      color: AppTheme.backgroundDark,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.map_outlined, color: Colors.white38, size: 48),
            const SizedBox(height: 12),
            Text(
              '$name is not available in this build.',
              style: const TextStyle(color: Colors.white54, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            const Text(
              'Contact your administrator to enable this map provider.',
              style: TextStyle(color: Colors.white38, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
