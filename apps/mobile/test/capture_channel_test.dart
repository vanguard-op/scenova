import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/services/capture_channel.dart';
import 'package:scenova/services/capture_intake.dart';

/// The capture channel is the iOS share-extension and Android selection-action
/// entry point. These cover the handoff paths that carry risk: a selection that
/// arrived before the UI was up, a live selection, and an empty one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel(CaptureChannel.channelName);
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  void mockPlatform(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, handler);
  }

  testWidgets('asks for a selection that arrived before the UI was up', (
    tester,
  ) async {
    final calls = <String>[];
    mockPlatform((call) async {
      calls.add(call.method);
      return call.method == CaptureChannel.methodPendingSelection
          ? 'coming,'
          : null;
    });

    final capture = CaptureChannel();
    addTearDown(capture.dispose);
    final received = <CaptureSelection>[];
    capture.selections.listen(received.add);

    await capture.start();
    await tester.pump();

    expect(calls, <String>[
      CaptureChannel.methodPendingSelection,
      CaptureChannel.methodReady,
    ]);
    expect(received.single.text, 'coming');
    expect(received.single.isEmpty, isFalse);
  });

  testWidgets('receives a selection handed over while it is running', (
    tester,
  ) async {
    mockPlatform((_) async => null);

    final capture = CaptureChannel();
    addTearDown(capture.dispose);
    final received = <CaptureSelection>[];
    capture.selections.listen(received.add);
    await capture.start();

    await messenger.handlePlatformMessage(
      CaptureChannel.channelName,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall(CaptureChannel.methodCapture, <String, Object?>{
          'text': '  bank  ',
        }),
      ),
      (_) {},
    );
    await tester.pump();

    expect(received.single.text, 'bank');
  });

  testWidgets('an empty selection starts no lookup', (tester) async {
    mockPlatform((_) async => null);

    final capture = CaptureChannel();
    addTearDown(capture.dispose);
    final received = <CaptureSelection>[];
    capture.selections.listen(received.add);
    await capture.start();

    await messenger.handlePlatformMessage(
      CaptureChannel.channelName,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall(CaptureChannel.methodCapture, <String, Object?>{
          'text': '   ',
        }),
      ),
      (_) {},
    );
    await tester.pump();

    expect(received.single.isEmpty, isTrue);
  });

  testWidgets('starts without a platform entry point', (tester) async {
    // The extension or action is absent on this build; the app still opens so
    // the reader can type or paste a word.
    mockPlatform((_) async => throw MissingPluginException());

    final capture = CaptureChannel();
    addTearDown(capture.dispose);

    await capture.start();
    await tester.pump();
  });

  testWidgets('reads the selection action as the entry point', (tester) async {
    mockPlatform((call) async {
      if (call.method == CaptureChannel.methodEntryPoint) {
        return CaptureEntryPoint.selectionAction.wire;
      }
      return null;
    });

    final capture = CaptureChannel();
    addTearDown(capture.dispose);

    expect(await capture.entryPoint(), CaptureEntryPoint.selectionAction);
  });

  testWidgets('reads an ordinary launch as the app entry point', (
    tester,
  ) async {
    mockPlatform((call) async {
      if (call.method == CaptureChannel.methodEntryPoint) {
        return CaptureEntryPoint.app.wire;
      }
      return null;
    });

    final capture = CaptureChannel();
    addTearDown(capture.dispose);

    expect(await capture.entryPoint(), CaptureEntryPoint.app);
  });

  testWidgets('an absent entry point reads as the app', (tester) async {
    // The iOS extension's own process, web, and desktop have no host to ask, so
    // the shell opens the app rather than the in-place surface.
    mockPlatform((call) async => throw MissingPluginException());

    final capture = CaptureChannel();
    addTearDown(capture.dispose);

    expect(await capture.entryPoint(), CaptureEntryPoint.app);
  });

  testWidgets('closing the in-place view asks the platform to finish', (
    tester,
  ) async {
    final calls = <String>[];
    mockPlatform((call) async {
      calls.add(call.method);
      return null;
    });

    final capture = CaptureChannel();
    addTearDown(capture.dispose);

    await capture.finish();
    expect(calls, <String>[CaptureChannel.methodDismiss]);
  });

  testWidgets('closing without a host is a no-op', (tester) async {
    mockPlatform((call) async => throw MissingPluginException());

    final capture = CaptureChannel();
    addTearDown(capture.dispose);

    await capture.finish();
  });
}
