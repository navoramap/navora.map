import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navora_map/views/home/review_sheet_lifecycle.dart';

void main() {
  testWidgets(
    'review text controller stays alive through bottom-sheet dismissal',
    (tester) async {
      final controller = TextEditingController();
      ModalRoute<void>? reviewRoute;
      Future<void>? reviewSheet;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () {
                  reviewSheet = () async {
                    try {
                      await showModalBottomSheet<void>(
                        context: context,
                        builder: (sheetContext) {
                          reviewRoute = ModalRoute.of<void>(sheetContext);
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextField(controller: controller),
                              TextButton(
                                onPressed: () => Navigator.pop(sheetContext),
                                child: const Text('Close review'),
                              ),
                            ],
                          );
                        },
                      );
                    } finally {
                      await disposeControllerAfterRouteCompletes(
                        controller: controller,
                        route: reviewRoute,
                      );
                    }
                  }();
                },
                child: const Text('Open review'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open review'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Test yorum');
      await tester.tap(find.text('Close review'));
      await tester.pump();

      expect(tester.takeException(), isNull);

      await tester.pumpAndSettle();
      await reviewSheet;

      expect(tester.takeException(), isNull);
    },
  );
}
