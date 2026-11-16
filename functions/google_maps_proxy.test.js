const assert = require('node:assert/strict');
const { test } = require('node:test');
const { buildGoogleMapsRequest } = require('./google_maps_proxy');

test('builds a bounded Places text search with a server-owned field mask', () => {
  const request = buildGoogleMapsRequest({
    operation: 'searchText',
    query: '  kahve  ',
    location: { latitude: 41, longitude: 29 },
    fieldMask: 'places.*',
  });

  assert.equal(request.method, 'POST');
  assert.equal(
      request.url,
      'https://places.googleapis.com/v1/places:searchText',
  );
  assert.equal(request.body.textQuery, 'kahve');
  assert.equal(request.body.pageSize, 10);
  assert.equal(request.body.locationBias.circle.radius, 15000);
  assert.ok(request.fieldMask.includes('places.id'));
  assert.ok(!request.fieldMask.includes('*'));
});

test('builds a fixed Nearby Search request and rejects an excessive radius', () => {
  const request = buildGoogleMapsRequest({
    operation: 'searchNearby',
    location: { latitude: 41, longitude: 29 },
    radiusMeters: 50,
  });

  assert.equal(request.body.maxResultCount, 10);
  assert.equal(request.body.locationRestriction.circle.radius, 50);
  assert.throws(
      () => buildGoogleMapsRequest({
        operation: 'searchNearby',
        location: { latitude: 41, longitude: 29 },
        radiusMeters: 50001,
      }),
      { code: 'invalid-argument' },
  );
});

test('builds autocomplete and safely encodes place details IDs', () => {
  const autocomplete = buildGoogleMapsRequest({
    operation: 'autocomplete',
    query: 'Kadıköy',
  });
  const details = buildGoogleMapsRequest({
    operation: 'details',
    placeId: 'place/id',
  });

  assert.deepEqual(autocomplete.body.includedRegionCodes, ['tr']);
  assert.equal(
      details.url,
      'https://places.googleapis.com/v1/places/place%2Fid?languageCode=tr',
  );
  assert.equal(details.method, 'GET');
});

test('builds constrained Routes requests and rejects invalid coordinates', () => {
  const request = buildGoogleMapsRequest({
    operation: 'computeRoutes',
    origin: { latitude: 41, longitude: 29 },
    destination: { latitude: 40, longitude: 30 },
    travelMode: 'DRIVE',
    includeAlternativeRoutes: true,
  });

  assert.equal(request.body.travelMode, 'DRIVE');
  assert.equal(request.body.computeAlternativeRoutes, true);
  assert.deepEqual(request.body.extraComputations, ['TRAFFIC_ON_POLYLINE']);
  assert.ok(request.fieldMask.includes('travelAdvisory.speedReadingIntervals'));
  const walkingRequest = buildGoogleMapsRequest({
    operation: 'computeRoutes',
    origin: { latitude: 41, longitude: 29 },
    destination: { latitude: 40, longitude: 30 },
    travelMode: 'WALK',
  });
  assert.ok(!walkingRequest.fieldMask.includes('travelAdvisory'));
  assert.ok(!walkingRequest.body.routingPreference);
  assert.throws(
      () => buildGoogleMapsRequest({
        operation: 'computeRoutes',
        origin: { latitude: 91, longitude: 29 },
        destination: { latitude: 40, longitude: 30 },
        travelMode: 'DRIVE',
      }),
      { code: 'invalid-argument' },
  );
});

test('rejects unknown operations and oversized search input', () => {
  assert.throws(
      () => buildGoogleMapsRequest({ operation: 'proxy', url: 'https://example.com' }),
      { code: 'invalid-argument' },
  );
  assert.throws(
      () => buildGoogleMapsRequest({
        operation: 'searchText',
        query: 'x'.repeat(201),
      }),
      { code: 'invalid-argument' },
  );
});
