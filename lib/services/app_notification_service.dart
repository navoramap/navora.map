import 'package:flutter/material.dart';

class AppNotificationService {
  AppNotificationService._();

  static final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  static AppNotification? _pendingNotification;
  static Duration _pendingDuration = const Duration(seconds: 4);
  static double _pendingKeyboardInset = 0;
  static bool _pendingShowScheduled = false;

  static void show(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 4),
    double keyboardInset = 0,
  }) {
    final notification = AppNotification(
      message: message,
      actionLabel: actionLabel,
      onAction: onAction,
    );
    final messenger = scaffoldMessengerKey.currentState;
    if (messenger == null) {
      _pendingNotification = notification;
      _pendingDuration = duration;
      _pendingKeyboardInset = keyboardInset;
      if (!_pendingShowScheduled) {
        _pendingShowScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _pendingShowScheduled = false;
          final pending = _pendingNotification;
          final pendingMessenger = scaffoldMessengerKey.currentState;
          if (pending == null || pendingMessenger == null) return;
          _pendingNotification = null;
          _present(
            pendingMessenger,
            pending,
            _pendingDuration,
            _pendingKeyboardInset,
          );
          _pendingKeyboardInset = 0;
        });
      }
      return;
    }

    _pendingNotification = null;
    _pendingKeyboardInset = 0;
    _present(messenger, notification, duration, keyboardInset);
  }

  static void _present(
    ScaffoldMessengerState messenger,
    AppNotification notification,
    Duration duration,
    double keyboardInset,
  ) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: _NotificationCard(notification: notification),
          duration: duration,
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.transparent,
          elevation: 0,
          padding: EdgeInsets.zero,
          margin: EdgeInsets.fromLTRB(16, 0, 16, 112 + keyboardInset),
          dismissDirection: DismissDirection.none,
        ),
      );
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

class _NotificationCard extends StatelessWidget {
  final AppNotification notification;

  const _NotificationCard({required this.notification});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: const Color(0xFF242424),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                notification.message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                  decoration: TextDecoration.none,
                ),
              ),
              if (notification.actionLabel != null &&
                  notification.onAction != null) ...[
                const SizedBox(height: 6),
                TextButton(
                  onPressed: () {
                    AppNotificationService.scaffoldMessengerKey.currentState
                        ?.hideCurrentSnackBar();
                    notification.onAction!();
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFFFA14A),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(40, 40),
                  ),
                  child: Text(notification.actionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
