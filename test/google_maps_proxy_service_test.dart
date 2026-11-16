import 'package:flutter_test/flutter_test.dart';
import 'package:navora_map/services/google_maps_proxy_service.dart';

void main() {
  test('normalizes nested callable maps for autocomplete responses', () {
    final response = NavoraGoogleMapsProxyService.normalizeResponse({
      'suggestions': [
        {
          'placePrediction': {
            'text': {'text': 'Kafe'},
            'structuredFormat': {
              'mainText': {'text': 'Kafe'},
              'secondaryText': {'text': 'İstanbul'},
            },
          },
        },
      ],
    });

    final suggestions = response['suggestions'] as List<dynamic>;
    final suggestion = suggestions.single as Map<String, dynamic>;
    final prediction = suggestion['placePrediction'] as Map<String, dynamic>;
    final structured = prediction['structuredFormat'] as Map<String, dynamic>;

    expect(structured['mainText'], isA<Map<String, dynamic>>());
    expect(
      (structured['secondaryText'] as Map<String, dynamic>)['text'],
      'İstanbul',
    );
  });

  test('rejects callable responses with non-string map keys', () {
    expect(
      () => NavoraGoogleMapsProxyService.normalizeResponse({
        'suggestions': [
          {1: 'invalid'},
        ],
      }),
      throwsFormatException,
    );
  });
}
