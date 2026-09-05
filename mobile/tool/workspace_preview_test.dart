import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'workspace_preview.dart';

void main() {
  testWidgets('preview pumps and navigates from tasks into a conversation', (
    tester,
  ) async {
    await tester.pumpWidget(const WorkspacePreviewApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('设计预览 · 模拟数据'), findsOneWidget);
    expect(find.text('preview-build'), findsOneWidget);
    expect(find.text('preview-logs'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('preview-scene-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('任务列表').last);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('任务'), findsOneWidget);
    expect(find.text('打磨移动端工作区'), findsOneWidget);

    await tester.tap(find.text('打磨移动端工作区'));
    await tester.pump();
    expect(find.text('读取文件 · 模拟工具输出'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('preview controls fit 320px with large text', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(const WorkspacePreviewApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final picker = find.byKey(const ValueKey('preview-scene-picker'));
    expect(find.text('设计预览 · 模拟数据'), findsOneWidget);
    expect(tester.getSize(picker).height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });
}
