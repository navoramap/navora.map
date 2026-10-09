import 'package:flutter/material.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  int _chatTab = 0; // 0: Akış, 1: Genel, 2: Şifreli Oda

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Navora Sosyal & Sohbet', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF111111),
        elevation: 1,
        centerTitle: true,
      ),
      body: Column(
        children: [
          Container(
            color: const Color(0xFF151515),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildTabButton('Yakın Akış', 0),
                _buildTabButton('Genel Oda', 1),
                _buildTabButton('Şifreli Oda', 2),
              ],
            ),
          ),
          Expanded(
            child: _chatTab == 0
                ? _buildNearbyFeed()
                : _chatTab == 1
                    ? _buildGeneralRoom()
                    : _buildEncryptedRoom(),
          ),
          const SizedBox(height: 70),
        ],
      ),
    );
  }

  Widget _buildTabButton(String title, int index) {
    final isSelected = _chatTab == index;
    return TextButton(
      onPressed: () => setState(() => _chatTab = index),
      child: Text(
        title,
        style: TextStyle(
          color: isSelected ? const Color(0xFFFF6B00) : const Color(0xFFB8B8B8),
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          fontSize: 15,
        ),
      ),
    );
  }

  Widget _buildNearbyFeed() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: 5,
      itemBuilder: (context, index) {
        final isPro = index == 0;
        final userName = isPro ? 'Vcan Özdemir' : 'Mehmet Demir';
        final distanceText = isPro ? '420 m uzaklıkta' : '1.2 km uzaklıkta';

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const CircleAvatar(backgroundImage: NetworkImage('https://picsum.photos/50'), radius: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              userName,
                              style: const TextStyle(fontWeight: FontWeight.bold),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isPro) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1A140D),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: const Color(0xFFFFD77A).withValues(alpha: 0.75)),
                              ),
                              child: const Text(
                                'VIP',
                                style: TextStyle(
                                  color: Color(0xFFFFE3A1),
                                  fontSize: 8,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(distanceText, style: const TextStyle(color: Color(0xFFB8B8B8), fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 10),
                Text('E-5 karayolu üzerinde trafik yoğunluğu var, alternatif güzergahı kullanın dostlar! #${index + 1}'),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildGeneralRoom() {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: const [
              ChatBubble(name: 'Caner', text: 'Herkese iyi yolculuklar!', isPro: true),
              ChatBubble(name: 'Zeynep', text: 'Bugün hava sürüş için harika.'),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              const Expanded(child: TextField(decoration: InputDecoration(hintText: 'Genel odaya mesaj yaz...'))),
              IconButton(icon: const Icon(Icons.send, color: Color(0xFFFF6B00)), onPressed: () {}),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEncryptedRoom() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.lock_outline, size: 64, color: Color(0xFFFF6B00)),
          const SizedBox(height: 16),
          const Text('Şifreli Yakındaki Oda', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Konumunuzdaki diğer kullanıcılarla güvenli ve şifreli iletişim kurmak için bir oda kodu girin.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 24),
          TextField(
            decoration: InputDecoration(
              labelText: 'Oda Kodu / Şifre',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
              filled: true,
              fillColor: const Color(0xFF191919),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6B00), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
              onPressed: () {},
              child: const Text('Odaya Katıl veya Kur', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}

class ChatBubble extends StatelessWidget {
  final String name;
  final String text;
  final bool isPro;
  const ChatBubble({
    super.key,
    required this.name,
    required this.text,
    this.isPro = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFF151515), borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFFFF6B00))),
              if (isPro) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A140D),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFFD77A).withValues(alpha: 0.75)),
                  ),
                  child: const Text(
                    'VIP',
                    style: TextStyle(
                      color: Color(0xFFFFE3A1),
                      fontSize: 8,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(text),
        ],
      ),
    );
  }
}
