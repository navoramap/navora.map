import 'dart:async';

import 'package:flutter/material.dart';

class AppNotificationService {
  AppNotificationService._();

  static final navigatorKey = GlobalKey<NavigatorState>();
  static final ValueNotifier<AppNotification?> current =
      ValueNotifier<AppNotification?>(null);
  static Timer? _dismissTimer;

  static void show(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 4),
  }) {
    _dismissTimer?.cancel();
    current.value = AppNotification(
      message: message,
      actionLabel: actionLabel,
      onAction: onAction,
    );
    _dismissTimer = Timer(duration, () => current.value = null);
  }
}

class AppNotification {
  const AppNotification({
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
}

class AppNotificationLayer extends StatelessWidget {
  const AppNotificationLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppNotification?>(
      valueListenable: AppNotificationService.current,
      builder: (context, notification, _) {
        if (notification == null) return const SizedBox.shrink();

        return SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 112),
              child: Material(
                color: const Color(0xFF242424),
                elevation: 12,
                shadowColor: Colors.black87,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF383838)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          notification.message,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      if (notification.actionLabel != null &&
                          notification.onAction != null)
                        TextButton(
                          onPressed: () {
                            final action = notification.onAction!;
                            AppNotificationService.current.value = null;
                            AppNotificationService._dismissTimer?.cancel();
                            action();
                          },
                          child: Text(notification.actionLabel!),
                        ),
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            AppNotificationService._dismissTimer?.cancel();
                            AppNotificationService.current.value = null;
                          },
                          icon: const Icon(
                            Icons.close_rounded,
                            color: Colors.white70,
                            size: 18,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
