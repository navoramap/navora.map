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
  )..repeat(reverse: true);

  @override
  void dispose() {
    _routeAnimation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFF101416),
    child: DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.15),
          radius: 1.15,
          colors: [Color(0xFF20272B), Color(0xFF101416)],
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 220,
                height: 164,
                decoration: BoxDecoration(
                  color: const Color(0xFF171D20),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.07),
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 32,
                      offset: Offset(0, 16),
                    ),
                    BoxShadow(
                      color: Color(0x22FF7A00),
                      blurRadius: 38,
                      spreadRadius: -10,
                    ),
                  ],
                ),
                child: Center(
                  child: AnimatedBuilder(
                    animation: _routeAnimation,
                    builder: (context, child) => CustomPaint(
                      size: const Size(158, 108),
                      painter: _NavoraRouteLoadingPainter(
                        progress: _routeAnimation.value,
                      ),
                    ),
                  ),
                ),
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
                  const Icon(
                    Icons.near_me_rounded,
                    color: Color(0xFFFF7A00),
                    size: 15,
                  ),
                  const SizedBox(width: 7),
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
    ),
  );
}

class _NavoraRouteLoadingPainter extends CustomPainter {
  final double progress;

  const _NavoraRouteLoadingPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
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
        ..color = const Color(0xFF344047)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawPath(
      route,
      Paint()
        ..color = const Color(0xFF5A666B)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );

    const dashLength = 6.0;
    for (var distance = 0.0; distance < metric.length; distance += 12) {
      canvas.drawPath(
        metric.extractPath(
          distance,
          (distance + dashLength).clamp(0, metric.length),
        ),
        Paint()
          ..color = const Color(0xFFFF9A3D).withValues(alpha: 0.78)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }

    final tangent = metric.getTangentForOffset(metric.length * progress);
    if (tangent == null) return;
    canvas.drawCircle(
      tangent.position,
      14,
      Paint()..color = const Color(0x44FF7A00),
    );
    canvas.drawCircle(
      tangent.position,
      7,
      Paint()..color = const Color(0xFFFF7A00),
    );
    canvas.drawCircle(tangent.position, 2.5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_NavoraRouteLoadingPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
