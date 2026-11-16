import 'package:flutter/material.dart';

Future<void> disposeControllerAfterRouteCompletes({
  required TextEditingController controller,
  required ModalRoute<dynamic>? route,
}) async {
  if (route == null) {
    controller.dispose();
    return;
  }

  try {
    await route.completed;
  } finally {
    controller.dispose();
  }
}
