import 'package:cloud_functions/cloud_functions.dart';

class NavoraGoogleMapsProxyService {
  static final HttpsCallable _callable = FirebaseFunctions.instanceFor(
    region: 'europe-west1',
  ).httpsCallable('proxyGoogleMaps');

  static Future<Map<String, dynamic>> call(
    String operation,
    Map<String, dynamic> parameters,
  ) async {
    final result = await _callable.call({
      ...parameters,
      'operation': operation,
    });
    return normalizeResponse(result.data);
  }

  static Map<String, dynamic> normalizeResponse(Object? value) {
    if (value is! Map<Object?, Object?>) {
      throw StateError('Harita servisinden geçersiz yanıt alındı.');
    }
    return _normalizeMap(value);
  }

  static Map<String, dynamic> _normalizeMap(Map<Object?, Object?> value) {
    final normalized = <String, dynamic>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        throw const FormatException(
          'Harita servisinden geçersiz yanıt alındı.',
        );
      }
      normalized[key] = _normalizeValue(entry.value);
    }
    return normalized;
  }

  static Object? _normalizeValue(Object? value) {
    if (value is Map<Object?, Object?>) return _normalizeMap(value);
    if (value is List<Object?>) {
      return value.map(_normalizeValue).toList(growable: false);
    }
    return value;
  }
}
