const { HttpsError } = require('firebase-functions/v2/https');

const PLACES_BASE_URL = 'https://places.googleapis.com/v1';
const ROUTES_URL = 'https://routes.googleapis.com/directions/v2:computeRoutes';
const PLACE_SEARCH_FIELD_MASK = [
  'places.id',
  'places.displayName',
  'places.formattedAddress',
  'places.location',
  'places.types',
  'places.primaryType',
  'places.rating',
  'places.userRatingCount',
].join(',');
const PLACE_DETAILS_FIELD_MASK = [
  'displayName',
  'formattedAddress',
  'location',
  'types',
  'primaryType',
  'rating',
  'userRatingCount',
  'nationalPhoneNumber',
  'websiteUri',
  'regularOpeningHours.weekdayDescriptions',
  'currentOpeningHours.openNow',
].join(',');
const AUTOCOMPLETE_FIELD_MASK = [
  'suggestions.placePrediction.placeId',
  'suggestions.placePrediction.text',
  'suggestions.placePrediction.structuredFormat',
  'suggestions.placePrediction.distanceMeters',
].join(',');
const ROUTE_FIELD_MASK = [
  'routes.distanceMeters',
  'routes.duration',
  'routes.polyline.geoJsonLinestring',
  'routes.legs.steps.distanceMeters',
  'routes.legs.steps.navigationInstruction',
  'routes.legs.steps.startLocation',
].join(',');
const NEARBY_TYPES = [
  'store',
  'restaurant',
  'cafe',
  'gas_station',
  'hospital',
  'pharmacy',
  'park',
  'tourist_attraction',
  'shopping_mall',
  'bank',
  'school',
  'lodging',
  'museum',
  'bakery',
  'bar',
  'bus_station',
  'supermarket',
  'convenience_store',
];

function invalidArgument(message) {
  throw new HttpsError('invalid-argument', message);
}

function requireRecord(value, name) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    invalidArgument(`Geçersiz ${name}.`);
  }
  return value;
}

function requireText(value, name, maximumLength) {
  if (typeof value !== 'string') {
    invalidArgument(`Geçersiz ${name}.`);
  }
  const text = value.trim();
  if (text.length === 0 || text.length > maximumLength) {
    invalidArgument(`Geçersiz ${name}.`);
  }
  return text;
}

function readCoordinate(value, name) {
  const point = requireRecord(value, name);
  const latitude = point.latitude;
  const longitude = point.longitude;
  if (
    typeof latitude !== 'number' ||
    !Number.isFinite(latitude) ||
    latitude < -90 ||
    latitude > 90 ||
    typeof longitude !== 'number' ||
    !Number.isFinite(longitude) ||
    longitude < -180 ||
    longitude > 180
  ) {
    invalidArgument(`Geçersiz ${name}.`);
  }
  return { latitude, longitude };
}

function optionalLocation(data) {
  return data.location == null ? null : readCoordinate(data.location, 'konum');
}

function buildGoogleMapsRequest(input) {
  const data = requireRecord(input, 'harita isteği');
  switch (data.operation) {
    case 'searchText': {
      const body = {
        textQuery: requireText(data.query, 'arama metni', 200),
        languageCode: 'tr',
        regionCode: 'TR',
        pageSize: 10,
      };
      const location = optionalLocation(data);
      if (location) {
        body.locationBias = {
          circle: {
            center: location,
            radius: 15000,
          },
        };
      }
      return {
        operation: data.operation,
        url: `${PLACES_BASE_URL}/places:searchText`,
        method: 'POST',
        fieldMask: PLACE_SEARCH_FIELD_MASK,
        body,
      };
    }

    case 'searchNearby': {
      const location = readCoordinate(data.location, 'konum');
      const radius = data.radiusMeters ?? 50;
      if (
        typeof radius !== 'number' ||
        !Number.isFinite(radius) ||
        radius <= 0 ||
        radius > 50000
      ) {
        invalidArgument('Geçersiz arama yarıçapı.');
      }
      return {
        operation: data.operation,
        url: `${PLACES_BASE_URL}/places:searchNearby`,
        method: 'POST',
        fieldMask: PLACE_SEARCH_FIELD_MASK,
        body: {
          includedTypes: NEARBY_TYPES,
          maxResultCount: 10,
          rankPreference: 'DISTANCE',
          languageCode: 'tr',
          regionCode: 'TR',
          locationRestriction: {
            circle: {
              center: location,
              radius,
            },
          },
        },
      };
    }

    case 'autocomplete': {
      const body = {
        input: requireText(data.query, 'arama metni', 200),
        languageCode: 'tr',
        includedRegionCodes: ['tr'],
      };
      const location = optionalLocation(data);
      if (location) {
        body.locationBias = {
          circle: {
            center: location,
            radius: 25000,
          },
        };
        body.origin = location;
      }
      return {
        operation: data.operation,
        url: `${PLACES_BASE_URL}/places:autocomplete`,
        method: 'POST',
        fieldMask: AUTOCOMPLETE_FIELD_MASK,
        body,
      };
    }

    case 'details': {
      const placeId = requireText(data.placeId, 'yer kimliği', 256);
      return {
        operation: data.operation,
        url: `${PLACES_BASE_URL}/places/${encodeURIComponent(placeId)}?languageCode=tr`,
        method: 'GET',
        fieldMask: PLACE_DETAILS_FIELD_MASK,
      };
    }

    case 'computeRoutes': {
      const origin = readCoordinate(data.origin, 'başlangıç konumu');
      const destination = readCoordinate(
        data.destination,
        'varış konumu',
      );
      const travelMode = data.travelMode;
      if (!['DRIVE', 'WALK', 'BICYCLE'].includes(travelMode)) {
        invalidArgument('Geçersiz rota türü.');
      }
      const includeAlternativeRoutes = data.includeAlternativeRoutes ?? false;
      if (typeof includeAlternativeRoutes !== 'boolean') {
        invalidArgument('Geçersiz alternatif rota ayarı.');
      }
      const includeTraffic = travelMode === 'DRIVE';
      const fieldMask = [
        ROUTE_FIELD_MASK,
        ...(includeTraffic
          ? ['routes.travelAdvisory.speedReadingIntervals']
          : []),
      ].join(',');
      return {
        operation: data.operation,
        url: ROUTES_URL,
        method: 'POST',
        fieldMask,
        body: {
          origin: { location: { latLng: origin } },
          destination: { location: { latLng: destination } },
          travelMode,
          ...(includeTraffic && includeAlternativeRoutes
            ? { computeAlternativeRoutes: true }
            : {}),
          polylineEncoding: 'GEO_JSON_LINESTRING',
          polylineQuality: 'HIGH_QUALITY',
          ...(includeTraffic
            ? {
              routingPreference: 'TRAFFIC_AWARE_OPTIMAL',
              extraComputations: ['TRAFFIC_ON_POLYLINE'],
            }
            : {}),
        },
      };
    }

    default:
      invalidArgument('Desteklenmeyen harita işlemi.');
  }
}

module.exports = { buildGoogleMapsRequest };
