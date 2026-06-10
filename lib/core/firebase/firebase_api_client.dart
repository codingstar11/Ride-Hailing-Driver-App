import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:logger/logger.dart';

import '../mock_api/mock_api_client.dart';
import '../storage/location_entry.dart';
import '../utils/app_logger.dart';


/// Upload flow stays identical to [MockApiClient]:
///   Hive Queue → UploadWorker → LocationRemoteDatasource → FirebaseApiClient
///                                                          → Firestore
class FirebaseApiClient implements ApiClient {
  FirebaseApiClient({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;
  final _logger = Logger();

  // ── ApiClient interface ──────────────────────────────────────────────────

  @override
  Future<List<String>> uploadLocationBatch({
    required String tripId,
    required List<LocationEntry> locations,
    String? driverId,
  }) async {
    if (locations.isEmpty) return [];

    final batch = _firestore.batch();
    final tripRef = _firestore.collection('trips').doc(tripId);
    final locationsRef = tripRef.collection('locations');

    final uploadedAt = FieldValue.serverTimestamp();

    for (final entry in locations) {
      final docRef = locationsRef.doc(entry.uuid);
      batch.set(docRef, {
        'tripId': tripId,
        'latitude': entry.latitude,
        'longitude': entry.longitude,
        'accuracy': entry.accuracy,
        'timestamp': entry.timestamp.toIso8601String(),
        'uploadedAt': uploadedAt,
        if (driverId != null) 'driverId': driverId,
        // Preserve upload ordering — clients sort by this when replaying.
        'sequenceTimestamp': entry.timestamp.millisecondsSinceEpoch,
      });
    }

    await batch.commit();

    final ackIds = locations.map((e) => e.uuid).toList();
    _logger.i(
      '[FirebaseAPI] Uploaded ${ackIds.length} locations  trip=$tripId',
    );
    AppLogger.info(
      'FIREBASE_API',
      'Batch committed to Firestore  count=${ackIds.length}  trip=$tripId',
    );
    return ackIds;
  }

  @override
  Future<void> reportTripStarted(String tripId) async {
    try {
      await _firestore.collection('trips').doc(tripId).set(
        {
          'tripId': tripId,
          'status': 'active',
          'startedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      _logger.i('[FirebaseAPI] Trip started  trip=$tripId');
    } catch (e) {
      _logger.w('[FirebaseAPI] reportTripStarted failed (non-critical): $e');
      // Non-fatal — matches MockApiClient behaviour.
    }
  }

  @override
  Future<void> reportTripEnded({
    required String tripId,
    required int totalPoints,
  }) async {
    try {
      await _firestore.collection('trips').doc(tripId).set(
        {
          'status': 'completed',
          'endedAt': FieldValue.serverTimestamp(),
          'totalPoints': totalPoints,
        },
        SetOptions(merge: true),
      );
      _logger.i(
          '[FirebaseAPI] Trip ended  trip=$tripId  totalPoints=$totalPoints');
    } catch (e) {
      _logger.w('[FirebaseAPI] reportTripEnded failed (non-critical): $e');
    }
  }
}