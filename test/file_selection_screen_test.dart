import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/features/home/presentation/file_selection_screen.dart';

void main() {
  testWidgets(
    'shows selectable file categories and category-specific empty state',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: FileSelectionScreen()));

      expect(find.text('صور'), findsWidgets);
      expect(find.text('فيديوهات'), findsWidgets);
      expect(find.text('صوتيات'), findsWidgets);
      expect(find.text('تطبيقات'), findsWidgets);
      expect(find.text('ملفات'), findsWidgets);
      expect(find.text('إرسال'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );

      await tester.tap(find.text('فيديوهات').first);
      await tester.pumpAndSettle();

      expect(
        find.text('استعرض فيديوهات لإضافتها إلى قائمة الإرسال.'),
        findsOneWidget,
      );
    },
  );
}
