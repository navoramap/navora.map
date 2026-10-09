import 'package:flutter/material.dart';

class MapPage extends StatelessWidget {
  final List<Color> navoraGradient;

  const MapPage({super.key, required this.navoraGradient});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Harita Alanı Simülasyonu
          Container(
            color: const Color(0xFF1B1B1B),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.map_outlined, size: 80, color: Colors.orange.shade400),
                  const SizedBox(height: 12),
                  const Text(
                    'Google Maps Harita Görünümü Aktif',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFFFFCCAA)),
                  ),
                ],
              ),
            ),
          ),
          // Üst Arama Çubuğu ve Filtreler
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: Column(
              children: [
                Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(24),
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'Yol, konum veya mekan arayın...',
                      prefixIcon: const Icon(Icons.search, color: Color(0xFFFF6B00)),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.tune, color: Color(0xFFFF6B00)),
                        onPressed: () {},
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: const Color(0xFF191919),
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _buildFilterChip('Yakıt İstasyonları', Icons.local_gas_station, true),
                      _buildFilterChip('Otoparklar', Icons.local_parking, false),
                      _buildFilterChip('Restoranlar', Icons.restaurant, false),
                      _buildFilterChip('Elektrik Şarj', Icons.ev_station, false),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, IconData icon, bool isSelected) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      child: FilterChip(
        selected: isSelected,
        label: Text(label),
        avatar: Icon(icon, size: 16, color: isSelected ? Colors.white : const Color(0xFFFF6B00)),
        onSelected: (bool value) {},
        selectedColor: const Color(0xFFFF6B00),
        checkmarkColor: Colors.white,
        labelStyle: TextStyle(
          color: isSelected ? Colors.white : const Color(0xFFE0E0E0),
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
        backgroundColor: const Color(0xFF191919),
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }
}
