import 'package:flutter/material.dart';

String formatNavoraPoints(int n) {
  final negative = n < 0;
  final digits = n.abs().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    final remaining = digits.length - i;
    if (i > 0 && remaining % 3 == 0) buffer.write('.');
    buffer.write(digits[i]);
  }
  return negative ? '-$buffer' : buffer.toString();
}

class NavoraRank {
  final String name;
  final int minPoints;

  const NavoraRank(this.name, this.minPoints);

  static const List<NavoraRank> ladder = [
    NavoraRank('Kaşif', 0),
    NavoraRank('Yolcu', 500),
    NavoraRank('Gezgin', 1500),
    NavoraRank('Kaptan', 3000),
  ];

  static NavoraRank current(int points) {
    var rank = ladder.first;
    for (final item in ladder) {
      if (points >= item.minPoints) rank = item;
    }
    return rank;
  }

  static NavoraRank? next(int points) {
    for (final item in ladder) {
      if (points < item.minPoints) return item;
    }
    return null;
  }

  static double progress(int points) {
    final upcoming = next(points);
    if (upcoming == null) return 1;
    final currentMin = current(points).minPoints;
    final span = upcoming.minPoints - currentMin;
    if (span <= 0) return 1;
    return ((points - currentMin) / span).clamp(0.0, 1.0);
  }
}

class NavoraReward {
  final String id;
  final String title;
  final String subtitle;
  final int cost;
  final IconData icon;
  final bool oneTime;

  const NavoraReward({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.cost,
    required this.icon,
    this.oneTime = false,
  });
}

const List<NavoraReward> navoraRewards = [
  NavoraReward(
    id: 'room',
    title: 'Ek sohbet odası',
    subtitle: 'Günlük hak bitince 1 ekstra oda',
    cost: 200,
    icon: Icons.meeting_room_outlined,
  ),
  NavoraReward(
    id: 'ai',
    title: 'Ek Navora AI sorusu',
    subtitle: 'Günlük limitin üzerine +1 soru',
    cost: 150,
    icon: Icons.auto_awesome,
  ),
  NavoraReward(
    id: 'frame',
    title: 'Profil çerçevesi',
    subtitle: 'Avatarına altın keşif çerçevesi',
    cost: 400,
    icon: Icons.workspace_premium_outlined,
    oneTime: true,
  ),
  NavoraReward(
    id: 'theme',
    title: 'Aurora harita teması',
    subtitle: 'Profildeki harita stiline eklenir',
    cost: 350,
    icon: Icons.palette_outlined,
    oneTime: true,
  ),
  NavoraReward(
    id: 'pro_discount',
    title: 'Navora Pro indirimi',
    subtitle: 'Yükseltmede %20 puan indirimi (tam Pro satılmaz)',
    cost: 500,
    icon: Icons.local_offer_outlined,
    oneTime: true,
  ),
];

const List<Map<String, String>> navoraEarnRules = [
  {'title': 'Rota tamamla', 'detail': 'Her biten yolculuk', 'points': '+20–50'},
  {
    'title': '90+ sürüş skoru',
    'detail': 'Güvenli ve akıcı sürüş',
    'points': '+15',
  },
  {
    'title': 'Yeni şehir',
    'detail': 'İlk kez ziyaret edilen şehir',
    'points': '+50',
  },
  {
    'title': 'Topluluk bildirimi',
    'detail': 'Trafik, kaza veya radar',
    'points': '+25',
  },
  {
    'title': 'Gece sürüşü',
    'detail': '22:00 sonrası tamamlanan rota',
    'points': '+20',
  },
  {
    'title': 'E-şarj durağı',
    'detail': 'Şarj noktası kullanımı',
    'points': '+10',
  },
];

class NavoraPointsSheet extends StatelessWidget {
  final int points;
  final int monthEarned;
  final int monthSpent;
  final int bonusChatRooms;
  final int bonusAiQueries;
  final bool hasProfileFrame;
  final bool hasAuroraTheme;
  final bool hasProDiscount;
  final int citiesVisited;
  final int communityReports;
  final List<Map<String, dynamic>> ledger;
  final VoidCallback onChanged;
  final bool Function(NavoraReward reward) onRedeem;

  const NavoraPointsSheet({
    super.key,
    required this.points,
    required this.monthEarned,
    required this.monthSpent,
    required this.bonusChatRooms,
    required this.bonusAiQueries,
    required this.hasProfileFrame,
    required this.hasAuroraTheme,
    required this.hasProDiscount,
    required this.citiesVisited,
    required this.communityReports,
    required this.ledger,
    required this.onChanged,
    required this.onRedeem,
  });

  bool _owned(String id) {
    switch (id) {
      case 'frame':
        return hasProfileFrame;
      case 'theme':
        return hasAuroraTheme;
      case 'pro_discount':
        return hasProDiscount;
      default:
        return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final rank = NavoraRank.current(points);
    final nextRank = NavoraRank.next(points);
    final progress = NavoraRank.progress(points);
    final toNext = nextRank == null ? 0 : nextRank.minPoints - points;
    const nextBadgeGoal = 20;
    final badgeProgress = (communityReports / nextBadgeGoal).clamp(0.0, 1.0);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.96,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFF111111),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 28),
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Navora Puan',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Icon(
                      Icons.phone_android_rounded,
                      color: Color(0xFFB8B8B8),
                      size: 14,
                    ),
                    SizedBox(width: 6),
                    Text(
                      'Puanlar bu cihazda saklanır',
                      style: TextStyle(color: Color(0xFFB8B8B8), fontSize: 11),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [
                      Color(0xFF1A120D),
                      Color(0xFF24160F),
                      Color(0xFF1D1D1D),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: const Color(0xFFFF8A3D),
                    width: 1.2,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Bakiye',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      formatNavoraPoints(points),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            rank.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          nextRank == null
                              ? 'En yüksek seviye'
                              : '${formatNavoraPoints(toNext)} puan → ${nextRank.name}',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 8,
                        backgroundColor: Colors.white24,
                        color: Colors.amber,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Kaşif → Yolcu → Gezgin → Kaptan',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.8),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _statCard(
                      'Bu ay kazandığın',
                      '+${formatNavoraPoints(monthEarned)}',
                      Colors.green,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _statCard(
                      'Bu ay harcadığın',
                      '-${formatNavoraPoints(monthSpent)}',
                      Colors.orange,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _chip('Oda hakkı: $bonusChatRooms'),
                  _chip('AI hakkı: $bonusAiQueries'),
                ],
              ),
              const SizedBox(height: 22),
              const Text(
                'Sıradaki rozet',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF1B1B1B),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    const BoxShadow(
                      color: Color(0xFF2B2B2B),
                      blurRadius: 8,
                      offset: Offset(-3, -3),
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 8,
                      offset: const Offset(3, 3),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Topluluk Lideri',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$communityReports / $nextBadgeGoal bildirim  •  $citiesVisited şehir keşfedildi',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade400,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: badgeProgress,
                        minHeight: 7,
                        backgroundColor: const Color(0xFF3A3A3A),
                        color: const Color(0xFFFF6B00),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              const Text(
                'Nasıl kazanılır?',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              ...navoraEarnRules.map(
                (rule) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1B1B1B),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0xFF2B2B2B),
                          blurRadius: 7,
                          offset: Offset(-3, -3),
                        ),
                        BoxShadow(
                          color: Colors.black54,
                          blurRadius: 7,
                          offset: Offset(3, 3),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                rule['title']!,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                              Text(
                                rule['detail']!,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey.shade400,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          rule['points']!,
                          style: TextStyle(
                            color: const Color(0xFFFF8C42),
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Takas',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'SOS ve temel navigasyon kilitlenmez. Puan yalnızca küçük ayrıcalıklar içindir.',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
              ),
              const SizedBox(height: 8),
              ...navoraRewards.map((reward) {
                final owned = _owned(reward.id);
                final canAfford = points >= reward.cost;
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1B1B1B),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF363636)),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0xFF2B2B2B),
                        blurRadius: 8,
                        offset: Offset(-3, -3),
                      ),
                      BoxShadow(
                        color: Colors.black54,
                        blurRadius: 8,
                        offset: Offset(3, 3),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: const Color(0xFFFF6B00)
                            .withValues(alpha: 0.1),
                        child: Icon(
                          reward.icon,
                          color: const Color(0xFFFF6B00),
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              reward.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                            Text(
                              reward.subtitle,
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade400,
                              ),
                            ),
                            Text(
                              '${formatNavoraPoints(reward.cost)} puan',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFFFF6B00),
                              ),
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: owned
                            ? null
                            : () {
                                final ok = onRedeem(reward);
                                if (ok) onChanged();
                              },
                        child: Text(
                          owned
                              ? 'Alındı'
                              : canAfford
                              ? 'Takas et'
                              : 'Yetersiz',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            color: owned
                                ? Colors.grey
                                : canAfford
                                ? const Color(0xFFFF6B00)
                                : Colors.redAccent,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 8),
              const Text(
                'Hareketler',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              const SizedBox(height: 8),
              ...ledger.map((item) {
                final amount = item['amount'] as int;
                final earn = amount > 0;
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1B1B1B),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0xFF2B2B2B),
                        blurRadius: 7,
                        offset: Offset(-3, -3),
                      ),
                      BoxShadow(
                        color: Colors.black54,
                        blurRadius: 7,
                        offset: Offset(3, 3),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Icon(
                        earn ? Icons.south_west : Icons.north_east,
                        size: 18,
                        color: earn ? Colors.green : Colors.orange,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item['title'] as String,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                            Text(
                              '${item['detail']}  •  ${item['date']}',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade400,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '${earn ? '+' : ''}${formatNavoraPoints(amount)}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: earn
                              ? Colors.green.shade700
                              : Colors.orange.shade800,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  Widget _statCard(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1B1B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFFF8A3D).withValues(alpha: 0.35),
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF8A3D).withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1A120D),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFFFF8A3D).withValues(alpha: 0.5),
        ),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Color(0xFFFFB066),
        ),
      ),
    );
  }
}
