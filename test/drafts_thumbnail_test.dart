import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiro/data/repositories.dart';
import 'package:kiro/features/drafts/drafts_screen.dart';
import 'package:kiro/studio/studio_service.dart';

Draft _draft(String type, String path) => Draft(
      title: 't',
      content: '',
      mediaPath: path,
      mediaType: type,
      createdAt: DateTime(2026),
    );

void main() {
  test('video poster path sits next to the video', () {
    expect(StudioService.videoThumbPath('/x/video_1.mp4'), '/x/video_1.mp4.thumb.png');
  });

  testWidgets('a video draft without a poster shows a film icon and a play badge', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DraftThumbnail(draft: _draft('video', '/nope/v.mp4')))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
  });

  testWidgets('a missing image falls back to an icon instead of throwing', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DraftThumbnail(draft: _draft('image', '/nope/i.png')))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
