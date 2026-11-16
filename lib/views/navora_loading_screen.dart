import 'dart:math' as math;

import 'package:flutter/material.dart';

class NavoraLoadingScreen extends StatefulWidget {
  final String title;
  final String subtitle;

  const NavoraLoadingScreen({
    super.key,
    required this.title,
    required this.subtitle,
  });

  @override
  State<NavoraLoadingScreen> createState() => _NavoraLoadingScreenState();
}

class _NavoraLoadingScreenState extends State<NavoraLoadingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _routeAnimation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat();

  @override
  void dispose() {
    _routeAnimation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFF0C1215),
    child: Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.24),
                radius: 1.4,
                colors: [
                  Color(0xFF1A2428),
                  Color(0xFF11181B),
                  Color(0xFF0B1013),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          top: -70,
          left: -40,
          child: Container(
            width: 220,
            height: 220,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFFFF7A00),
              boxShadow: [
                BoxShadow(
                  color: Color(0x55FF8B3D),
                  blurRadius: 110,
                  spreadRadius: 6,
                ),
              ],
            ),
          ),
        ),
        Positioned(
          right: -100,
          bottom: -50,
          child: Container(
            width: 260,
            height: 260,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF3AB4FF),
              boxShadow: [
                BoxShadow(
                  color: Color(0x553AB4FF),
                  blurRadius: 120,
                  spreadRadius: 10,
                ),
              ],
            ),
          ),
        ),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedBuilder(
                  animation: _routeAnimation,
                  builder: (context, child) {
                    final glow = 0.7 + ((_routeAnimation.value * 0.35) % 1.0);
                    return Transform.scale(
                      scale: 0.96 + _routeAnimation.value * 0.06,
                      child: Container(
                        width: 230,
                        height: 170,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(32),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Color(0xFF1B2427),
                              Color(0xFF0F1518),
                              Color(0xFF0D1013),
                            ],
                          ),
                          boxShadow: [
                            const BoxShadow(
                              color: Color(0x44000000),
                              blurRadius: 28,
                              offset: Offset(0, 18),
                            ),
                            BoxShadow(
                              color: const Color(0xFFFF7A00).withValues(alpha: 0.25 * glow),
                              blurRadius: 36,
                              spreadRadius: -10,
                            ),
                          ],
                        ),
                        child: Center(
                          child: CustomPaint(
                            size: const Size(168, 118),
                            painter: _NavoraRouteLoadingPainter(
                              progress: _routeAnimation.value,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 28),
                Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.1,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.subtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF9BA5AA),
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 28),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          colors: [Color(0xFFFFB066), Color(0xFFFF7A00)],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFFF7A00).withValues(alpha: 0.45),
                            blurRadius: 10,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.near_me_rounded,
                        color: Colors.white,
                        size: 11,
                      ),
                    ),
                    const SizedBox(width: 9),
                    Text(
                      'NAVORA  ·  YOLUNU BUL',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _NavoraRouteLoadingPainter extends CustomPainter {
  final double progress;

  const _NavoraRouteLoadingPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * 0.34;

    canvas.drawCircle(
      center,
      radius + 18,
      Paint()
        ..color = const Color(0xFFFF7A00).withValues(alpha: 0.08)
        ..style = PaintingStyle.fill,
    );

    final orbitPaint = Paint()
      ..shader = SweepGradient(
        colors: const [
          Color(0xFFFFE9D1),
          Color(0xFFFFA949),
          Color(0xFFFF7A00),
          Color(0xFF6FE2FF),
          Color(0xFFFFE9D1),
        ],
        stops: const [0.0, 0.3, 0.55, 0.82, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2 + progress * 2.2 * math.pi,
      2.0 * math.pi,
      false,
      orbitPaint,
    );

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius * 1.15),
      math.pi / 8,
      1.75 * math.pi,
      false,
      Paint()
        ..color = const Color(0xFF26373D)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    final route = Path()
      ..moveTo(size.width * 0.08, size.height * 0.82)
      ..quadraticBezierTo(
        size.width * 0.32,
        size.height * 0.82,
        size.width * 0.32,
        size.height * 0.57,
      )
      ..cubicTo(
        size.width * 0.32,
        size.height * 0.32,
        size.width * 0.47,
        size.height * 0.24,
        size.width * 0.67,
        size.height * 0.24,
      )
      ..quadraticBezierTo(
        size.width * 0.9,
        size.height * 0.24,
        size.width * 0.92,
        size.height * 0.06,
      );

    final metrics = route.computeMetrics().toList();
    if (metrics.isEmpty) return;
    final metric = metrics.first;

    canvas.drawPath(
      route,
      Paint()
        ..color = const Color(0xFF2E383D)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 11
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawPath(
      route,
      Paint()
        ..color = const Color(0xFF7A8A92).withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round,
    );

    final dashLength = 7.0;
    for (var distance = 0.0; distance < metric.length; distance += 12) {
      final end = (distance + dashLength).clamp(0, metric.length).toDouble();
      final segment = metric.extractPath(distance, end);
      canvas.drawPath(
        segment,
        Paint()
          ..color = const Color(0xFFFFB066)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6
          ..strokeCap = StrokeCap.round,
      );
    }

    final tangent = metric.getTangentForOffset(metric.length * progress);
    if (tangent == null) return;

    final dotPosition = tangent.position;
    canvas.drawCircle(
      dotPosition,
      16,
      Paint()..color = const Color(0x44FF7A00),
    );
    canvas.drawCircle(
      dotPosition,
      8,
      Paint()..color = const Color(0xFFFF7A00),
    );
    canvas.drawCircle(
      dotPosition,
      2.8,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_NavoraRouteLoadingPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
