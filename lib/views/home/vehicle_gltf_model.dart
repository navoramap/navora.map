import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

class GltfVehicleVertex {
  const GltfVehicleVertex(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;
}

class GltfVehicleFace {
  const GltfVehicleFace(this.vertices, this.color);

  final List<GltfVehicleVertex> vertices;
  final Color color;
}

class GltfVehicleModel {
  static const assetPath = 'assets/models/navora_vehicles.gltf';
  static const _vehicleNames = {
    'Araba',
    'Motosiklet',
    'Bisiklet',
    'Yürüyüş',
  };

  static Future<Map<String, List<GltfVehicleFace>>> load() async {
    final document = jsonDecode(
      await rootBundle.loadString(assetPath),
    ) as Map<String, dynamic>;
    final buffers = document['buffers'] as List<dynamic>? ?? const [];
    if (buffers.length != 1) {
      throw const FormatException('GLTF model must contain one buffer.');
    }

    final bufferUri = (buffers.single as Map<String, dynamic>)['uri'];
    if (bufferUri is! String || !bufferUri.startsWith('data:')) {
      throw const FormatException('GLTF model buffer must be embedded.');
    }
    final commaIndex = bufferUri.indexOf(',');
    if (commaIndex < 0 ||
        !bufferUri.substring(0, commaIndex).endsWith(';base64')) {
      throw const FormatException('GLTF model buffer URI is invalid.');
    }
    final binary = Uint8List.fromList(
      base64Decode(bufferUri.substring(commaIndex + 1)),
    );
    final byteData = ByteData.sublistView(binary);
    final bufferViews = document['bufferViews'] as List<dynamic>? ?? const [];
    final accessors = document['accessors'] as List<dynamic>? ?? const [];
    final materials = document['materials'] as List<dynamic>? ?? const [];
    final meshes = document['meshes'] as List<dynamic>? ?? const [];
    final models = <String, List<GltfVehicleFace>>{};
    final nodes = document['nodes'] as List<dynamic>? ?? const [];

    for (final node in nodes.whereType<Map<String, dynamic>>()) {
      final name = node['name'];
      final meshIndex = node['mesh'];
      if (name is! String ||
          !_vehicleNames.contains(name) ||
          meshIndex is! int ||
          meshIndex < 0 ||
          meshIndex >= meshes.length) {
        continue;
      }

      final mesh = meshes[meshIndex] as Map<String, dynamic>;
      final faces = <GltfVehicleFace>[];
      final primitives = mesh['primitives'] as List<dynamic>? ?? const [];
      for (final primitive in primitives.whereType<Map<String, dynamic>>()) {
        if (primitive['mode'] != null && primitive['mode'] != 4) continue;
        final attributes =
            primitive['attributes'] as Map<String, dynamic>? ?? const {};
        final positionIndex = attributes['POSITION'];
        if (positionIndex is! int ||
            positionIndex < 0 ||
            positionIndex >= accessors.length) {
          continue;
        }
        final positionAccessor =
            accessors[positionIndex] as Map<String, dynamic>;
        final positions = _readPositions(
          positionAccessor,
          bufferViews,
          byteData,
        );
        final indexAccessorIndex = primitive['indices'];
        final indices = indexAccessorIndex is int
            ? _readIndices(
                accessors[indexAccessorIndex] as Map<String, dynamic>,
                bufferViews,
                byteData,
              )
            : List<int>.generate(positions.length, (index) => index);
        final materialIndex = primitive['material'];
        final color = materialIndex is int &&
                materialIndex >= 0 &&
                materialIndex < materials.length
            ? _readMaterialColor(materials[materialIndex])
            : const Color(0xFFFF7616);

        for (var index = 0; index + 2 < indices.length; index += 3) {
          final a = indices[index];
          final b = indices[index + 1];
          final c = indices[index + 2];
          if (a < 0 ||
              b < 0 ||
              c < 0 ||
              a >= positions.length ||
              b >= positions.length ||
              c >= positions.length) {
            throw const FormatException('GLTF triangle index is out of range.');
          }
          faces.add(
            GltfVehicleFace(
              [positions[a], positions[b], positions[c]],
              color,
            ),
          );
        }
      }

      if (faces.isNotEmpty) models[name] = faces;
    }

    if (models.length != _vehicleNames.length) {
      throw const FormatException('GLTF model is missing a vehicle mesh.');
    }
    return models;
  }

  static List<GltfVehicleVertex> _readPositions(
    Map<String, dynamic> accessor,
    List<dynamic> bufferViews,
    ByteData byteData,
  ) {
    if (accessor['componentType'] != 5126 || accessor['type'] != 'VEC3') {
      throw const FormatException('GLTF positions must be float VEC3 values.');
    }
    final count = accessor['count'] as int;
    final viewIndex = accessor['bufferView'] as int;
    final view = bufferViews[viewIndex] as Map<String, dynamic>;
    final start = (view['byteOffset'] as int? ?? 0) +
        (accessor['byteOffset'] as int? ?? 0);
    final stride = view['byteStride'] as int? ?? 12;
    if (count < 0 || stride < 12 || start < 0 || start > byteData.lengthInBytes) {
      throw const FormatException('GLTF position accessor is invalid.');
    }

    return List<GltfVehicleVertex>.generate(count, (index) {
      final offset = start + index * stride;
      if (offset + 12 > byteData.lengthInBytes) {
        throw const FormatException('GLTF position data is truncated.');
      }
      final vertex = GltfVehicleVertex(
        byteData.getFloat32(offset, Endian.little),
        byteData.getFloat32(offset + 4, Endian.little),
        byteData.getFloat32(offset + 8, Endian.little),
      );
      if (!vertex.x.isFinite || !vertex.y.isFinite || !vertex.z.isFinite) {
        throw const FormatException('GLTF model has a non-finite vertex.');
      }
      return vertex;
    });
  }

  static List<int> _readIndices(
    Map<String, dynamic> accessor,
    List<dynamic> bufferViews,
    ByteData byteData,
  ) {
    if (accessor['type'] != 'SCALAR') {
      throw const FormatException('GLTF indices must be scalar values.');
    }
    final componentType = accessor['componentType'] as int;
    final bytesPerIndex = switch (componentType) {
      5121 => 1,
      5123 => 2,
      5125 => 4,
      _ => throw const FormatException('GLTF index type is unsupported.'),
    };
    final count = accessor['count'] as int;
    final viewIndex = accessor['bufferView'] as int;
    final view = bufferViews[viewIndex] as Map<String, dynamic>;
    final start = (view['byteOffset'] as int? ?? 0) +
        (accessor['byteOffset'] as int? ?? 0);
    final stride = view['byteStride'] as int? ?? bytesPerIndex;
    if (count < 0 ||
        stride < bytesPerIndex ||
        start < 0 ||
        start > byteData.lengthInBytes) {
      throw const FormatException('GLTF index accessor is invalid.');
    }
    return List<int>.generate(count, (index) {
      final offset = start + index * stride;
      if (offset + bytesPerIndex > byteData.lengthInBytes) {
        throw const FormatException('GLTF index data is truncated.');
      }
      return switch (componentType) {
        5121 => byteData.getUint8(offset),
        5123 => byteData.getUint16(offset, Endian.little),
        5125 => byteData.getUint32(offset, Endian.little),
        _ => throw const FormatException('GLTF index type is unsupported.'),
      };
    });
  }

  static Color _readMaterialColor(dynamic materialValue) {
    if (materialValue is! Map<String, dynamic>) {
      throw const FormatException('GLTF material is invalid.');
    }
    final pbr =
        materialValue['pbrMetallicRoughness'] as Map<String, dynamic>? ??
        const {};
    final factors = pbr['baseColorFactor'] as List<dynamic>? ??
        const [1.0, 0.46, 0.08, 1.0];
    if (factors.length != 4) {
      throw const FormatException('GLTF material color is invalid.');
    }
    final channels = factors
        .map((channel) => (channel as num).toDouble())
        .toList();
    if (channels.any((channel) => !channel.isFinite)) {
      throw const FormatException('GLTF material has an invalid color.');
    }
    int byteChannel(double value) => (value.clamp(0.0, 1.0) * 255).round();
    return Color.fromARGB(
      byteChannel(channels[3]),
      byteChannel(channels[0]),
      byteChannel(channels[1]),
      byteChannel(channels[2]),
    );
  }
}
