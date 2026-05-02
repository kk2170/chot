import 'dart:convert';

import 'package:chot/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows app title and input hint', (tester) async {
    await tester.pumpWidget(const ChotApp());
    await tester.pumpAndSettle();

    expect(find.text('chot · ノート 1'), findsOneWidget);
    expect(find.text('ノート 1 にメッセージを書く...'), findsOneWidget);
  });

  testWidgets('loads multiple notes from local storage', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({
      'chot_notes_state_v1':
          '{"selectedNoteId":"note-2","notes":[{"id":"note-1","title":"仕事","messages":[{"id":"m1","text":"明日の会議メモ","createdAt":"2026-04-29T10:00:00.000"}],"createdAt":"2026-04-29T10:00:00.000","updatedAt":"2026-04-29T10:00:00.000"},{"id":"note-2","title":"買い物","messages":[{"id":"m2","text":"牛乳を買う","createdAt":"2026-04-29T11:00:00.000"}],"createdAt":"2026-04-29T11:00:00.000","updatedAt":"2026-04-29T11:00:00.000"}]}'
    });

    await tester.pumpWidget(const ChotApp());
    await tester.pumpAndSettle();

    expect(find.text('仕事'), findsOneWidget);
    expect(find.text('買い物'), findsAtLeastNWidgets(1));
    expect(find.text('牛乳を買う'), findsAtLeastNWidgets(1));
  });

  testWidgets('falls back to a fresh note on corrupted saved state', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'chot_notes_state_v1': '{bad json',
    });

    await tester.pumpWidget(const ChotApp());
    await tester.pumpAndSettle();

    expect(find.text('chot · ノート 1'), findsOneWidget);
    expect(find.text('ノート 1 にメッセージを書く...'), findsOneWidget);
  });

  testWidgets('migrates legacy single-note messages', (tester) async {
    SharedPreferences.setMockInitialValues({
      'chot_messages': [
        '{"id":"1","text":"旧メモ","createdAt":"2026-04-29T10:00:00.000"}',
      ],
    });

    await tester.pumpWidget(const ChotApp());
    await tester.pumpAndSettle();

    expect(find.text('旧メモ'), findsOneWidget);
  });

  testWidgets('renames current note title', (tester) async {
    await tester.pumpWidget(const ChotApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('タイトル変更').first);
    await tester.pumpAndSettle();

    final dialogTextField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextFormField),
    );

    await tester.enterText(dialogTextField, '買い物リスト');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('chot · 買い物リスト'), findsOneWidget);
    expect(find.text('買い物リスト にメッセージを書く...'), findsOneWidget);
  });

  testWidgets('deletes current note and selects another note', (tester) async {
    SharedPreferences.setMockInitialValues({
      'chot_notes_state_v1':
          '{"selectedNoteId":"note-2","notes":[{"id":"note-1","title":"仕事","messages":[],"createdAt":"2026-04-29T10:00:00.000","updatedAt":"2026-04-29T10:00:00.000"},{"id":"note-2","title":"買い物","messages":[],"createdAt":"2026-04-29T11:00:00.000","updatedAt":"2026-04-29T11:00:00.000"}]}'
    });

    await tester.pumpWidget(const ChotApp());
    await tester.pumpAndSettle();

    expect(find.text('chot · 買い物'), findsOneWidget);

    await tester.tap(find.byTooltip('ノート削除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();

    expect(find.text('chot · 仕事'), findsOneWidget);
    expect(find.text('買い物'), findsNothing);
  });

  testWidgets('deleting last note creates a fresh note', (tester) async {
    await tester.pumpWidget(const ChotApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('ノート削除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();

    expect(find.text('chot · ノート 1'), findsOneWidget);
    expect(find.text('ノート 1 にメッセージを書く...'), findsOneWidget);
  });

  testWidgets('opens thread view from root message', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({
      'chot_notes_state_v1':
          '{"selectedNoteId":"note-1","notes":[{"id":"note-1","title":"仕事","messages":[{"id":"m1","text":"定例の議題を確認する","createdAt":"2026-04-29T10:00:00.000"},{"id":"m2","text":"資料は最新版です","createdAt":"2026-04-29T10:05:00.000","parentId":"m1"}],"createdAt":"2026-04-29T10:00:00.000","updatedAt":"2026-04-29T10:05:00.000"}]}'
    });

    await tester.pumpWidget(const ChotApp());
    await tester.pumpAndSettle();

    expect(find.text('定例の議題を確認する'), findsOneWidget);
    expect(find.text('返信 1件'), findsOneWidget);

    await tester.tap(find.text('返信 1件'));
    await tester.pumpAndSettle();

    expect(find.text('スレッド'), findsOneWidget);
    expect(find.text('資料は最新版です'), findsAtLeastNWidgets(1));
  });

  testWidgets('saves thread reply into local storage', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ChotApp());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'ノート 1 にメッセージを書く...',
      ),
      '親投稿',
    );
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded).first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('スレッドを開始'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'ノート 1 のスレッドに返信する...',
      ),
      'スレッド返信',
    );
    await tester.tap(find.byIcon(Icons.reply_rounded));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    final savedState = prefs.getString('chot_notes_state_v1');
    expect(savedState, isNotNull);

    final decoded = jsonDecode(savedState!) as Map<String, dynamic>;
    final notes = decoded['notes'] as List<dynamic>;
    final messages =
        (notes.first as Map<String, dynamic>)['messages'] as List<dynamic>;

    expect(messages, hasLength(2));
    expect((messages[0] as Map<String, dynamic>)['text'], '親投稿');
    expect((messages[1] as Map<String, dynamic>)['text'], 'スレッド返信');
    expect((messages[1] as Map<String, dynamic>)['parentId'],
        (messages[0] as Map<String, dynamic>)['id']);
  });

  testWidgets('edits root message and persists it', (tester) async {
    await tester.pumpWidget(const ChotApp());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'ノート 1 にメッセージを書く...',
      ),
      '元の投稿',
    );
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded).first);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('投稿メニュー'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('編集'));
    await tester.pumpAndSettle();

    final dialogTextField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextFormField),
    );

    await tester.enterText(dialogTextField, '更新した投稿');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('更新した投稿'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    final savedState = prefs.getString('chot_notes_state_v1');
    final decoded = jsonDecode(savedState!) as Map<String, dynamic>;
    final notes = decoded['notes'] as List<dynamic>;
    final messages =
        (notes.first as Map<String, dynamic>)['messages'] as List<dynamic>;

    expect((messages.first as Map<String, dynamic>)['text'], '更新した投稿');
  });

  testWidgets('deletes root message and its replies', (tester) async {
    SharedPreferences.setMockInitialValues({
      'chot_notes_state_v1':
          '{"selectedNoteId":"note-1","notes":[{"id":"note-1","title":"仕事","messages":[{"id":"m1","text":"親投稿","createdAt":"2026-04-29T10:00:00.000"},{"id":"m2","text":"返信","createdAt":"2026-04-29T10:05:00.000","parentId":"m1"}],"createdAt":"2026-04-29T10:00:00.000","updatedAt":"2026-04-29T10:05:00.000"}]}'
    });

    await tester.pumpWidget(const ChotApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('投稿メニュー'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();

    expect(find.text('親投稿'), findsNothing);
    expect(find.text('仕事 に、最初の投稿を。'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    final savedState = prefs.getString('chot_notes_state_v1');
    final decoded = jsonDecode(savedState!) as Map<String, dynamic>;
    final notes = decoded['notes'] as List<dynamic>;
    final messages =
        (notes.first as Map<String, dynamic>)['messages'] as List<dynamic>;

    expect(messages, isEmpty);
  });

  testWidgets('edits thread reply from thread pane', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({
      'chot_notes_state_v1':
          '{"selectedNoteId":"note-1","notes":[{"id":"note-1","title":"仕事","messages":[{"id":"m1","text":"親投稿","createdAt":"2026-04-29T10:00:00.000"},{"id":"m2","text":"元の返信","createdAt":"2026-04-29T10:05:00.000","parentId":"m1"}],"createdAt":"2026-04-29T10:00:00.000","updatedAt":"2026-04-29T10:05:00.000"}]}'
    });

    await tester.pumpWidget(const ChotApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('返信 1件'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('スレッドメッセージメニュー').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('編集'));
    await tester.pumpAndSettle();

    final dialogTextField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextFormField),
    );

    await tester.enterText(dialogTextField, '更新した返信');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('更新した返信'), findsAtLeastNWidgets(1));

    final prefs = await SharedPreferences.getInstance();
    final savedState = prefs.getString('chot_notes_state_v1');
    final decoded = jsonDecode(savedState!) as Map<String, dynamic>;
    final notes = decoded['notes'] as List<dynamic>;
    final messages =
        (notes.first as Map<String, dynamic>)['messages'] as List<dynamic>;

    expect((messages[1] as Map<String, dynamic>)['text'], '更新した返信');
    expect((messages[1] as Map<String, dynamic>)['parentId'], 'm1');
  });

  test('buildShareText joins note title and messages', () {
    final note = MemoNote(
      id: 'note-1',
      title: '買い物',
      createdAt: DateTime.parse('2026-04-29T10:00:00.000'),
      updatedAt: DateTime.parse('2026-04-29T11:00:00.000'),
      messages: [
        MemoMessage(
          id: 'm1',
          text: '牛乳を買う',
          createdAt: DateTime.parse('2026-04-29T11:00:00.000'),
        ),
        MemoMessage(
          id: 'm2',
          text: '特売なら2本',
          createdAt: DateTime.parse('2026-04-29T11:05:00.000'),
          parentId: 'm1',
        ),
      ],
    );

    expect(
      buildShareText(note),
      '買い物\n\n[04/29 11:00] 牛乳を買う\n  ↳ [04/29 11:05] 特売なら2本',
    );
  });

  test('buildShareText marks image attachments', () {
    final note = MemoNote(
      id: 'note-1',
      title: '旅行',
      createdAt: DateTime.parse('2026-04-29T10:00:00.000'),
      updatedAt: DateTime.parse('2026-04-29T11:00:00.000'),
      messages: [
        MemoMessage(
          id: 'm1',
          text: '',
          createdAt: DateTime.parse('2026-04-29T11:00:00.000'),
          imagePath: '/tmp/photo.png',
        ),
      ],
    );

    expect(buildShareText(note), '旅行\n\n[04/29 11:00] 画像');
  });

  test('memo message serialization preserves image path', () {
    final message = MemoMessage(
      id: 'm1',
      text: '写真メモ',
      createdAt: DateTime.parse('2026-04-29T11:00:00.000'),
      imagePath: '/tmp/image.jpg',
    );

    final restored = MemoMessage.fromJson(message.toJson());

    expect(restored.text, '写真メモ');
    expect(restored.imagePath, '/tmp/image.jpg');
  });

  test('buildMarkdownForNote formats note as markdown', () {
    final note = MemoNote(
      id: 'note-1',
      title: '旅行メモ',
      createdAt: DateTime.parse('2026-04-29T10:00:00.000'),
      updatedAt: DateTime.parse('2026-04-29T11:00:00.000'),
      messages: [
        MemoMessage(
          id: 'm1',
          text: '宿を確認する',
          createdAt: DateTime.parse('2026-04-29T11:00:00.000'),
        ),
        MemoMessage(
          id: 'm2',
          text: '地図のスクショ',
          createdAt: DateTime.parse('2026-04-29T11:05:00.000'),
          parentId: 'm1',
          imagePath: '/tmp/map.png',
        ),
      ],
    );

    expect(
      buildMarkdownForNote(note),
      '# 旅行メモ\n\n## 04/29 11:00\n宿を確認する\n\n### Thread\n- 04/29 11:05\n  地図のスクショ\n  ![](/tmp/map.png)',
    );
  });

  testWidgets('copies current note as markdown', (tester) async {
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(const ChotApp());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'ノート 1 にメッセージを書く...',
      ),
      'Markdown本文',
    );
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded).first);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Markdownをコピー'));
    await tester.pumpAndSettle();

    expect(clipboardText, startsWith('# ノート 1\n\n## '));
    expect(clipboardText, contains('Markdown本文'));
    expect(find.text('Markdown をコピーしました。'), findsOneWidget);
  });
}
