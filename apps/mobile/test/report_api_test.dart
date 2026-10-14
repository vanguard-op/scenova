import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scenova/models/report.dart';
import 'package:scenova/services/report_api.dart';

PendingReport _report(
  ReportReason reason, {
  String lookupId = 'lk_1',
  String? note,
}) {
  return PendingReport(
    lookupId: lookupId,
    reason: reason,
    note: note,
    clientReportId: 'cr_1',
    createdAt: DateTime.utc(2026, 1, 1),
  );
}

void main() {
  group('PendingReport', () {
    test('sends the frozen C-013 body', () {
      expect(_report(ReportReason.offensive).toJson(), <String, dynamic>{
        'lookupId': 'lk_1',
        'reason': 'offensive',
        'note': null,
        'clientReportId': 'cr_1',
      });
    });

    test('carries the reader note with the report', () {
      expect(
        _report(
          ReportReason.wrongMeaning,
          note: 'Showed the wrong sense',
        ).toJson(),
        <String, dynamic>{
          'lookupId': 'lk_1',
          'reason': 'wrong_meaning',
          'note': 'Showed the wrong sense',
          'clientReportId': 'cr_1',
        },
      );
    });

    test('keeps its key, reason, and note through the stored form', () {
      final stored = _report(
        ReportReason.lowQuality,
        note: 'Blurry and rushed',
      ).toStoredJson();
      final restored = PendingReport.fromStoredJson(stored);
      expect(restored.lookupId, 'lk_1');
      expect(restored.reason, ReportReason.lowQuality);
      expect(restored.note, 'Blurry and rushed');
      expect(restored.clientReportId, 'cr_1');
    });
  });

  group('HttpReportApi', () {
    HttpReportApi apiReturning(
      http.Response Function(http.Request request) handler,
    ) {
      return HttpReportApi(
        baseUrl: 'https://gateway.scenova.app',
        idTokenProvider: () async => 'token',
        client: MockClient((request) async => handler(request)),
      );
    }

    test('posts the report with the bearer token', () async {
      late http.Request captured;
      final api = apiReturning((r) {
        captured = r;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'reportId': 'rep_1',
            'status': 'queued',
          }),
          202,
        );
      });

      final queued = await api.report(_report(ReportReason.offensive));

      expect(queued, isTrue);
      expect(captured.method, 'POST');
      expect(captured.url.path, '/v1/reports');
      expect(captured.headers['authorization'], 'Bearer token');
      expect(jsonDecode(captured.body), <String, dynamic>{
        'lookupId': 'lk_1',
        'reason': 'offensive',
        'note': null,
        'clientReportId': 'cr_1',
      });
    });

    test('reads the service wording from the error body', () async {
      final api = apiReturning(
        (_) => http.Response(
          jsonEncode(<String, dynamic>{
            'code': 'note_too_long',
            'message': 'That note is too long.',
          }),
          400,
        ),
      );

      await expectLater(
        api.report(_report(ReportReason.other)),
        throwsA(
          isA<ReportApiException>()
              .having((e) => e.isRefused, 'isRefused', isTrue)
              .having((e) => e.code, 'code', 'note_too_long')
              .having((e) => e.message, 'message', 'That note is too long.'),
        ),
      );
    });

    test('a clip the caller does not own is refused, not retried', () async {
      final api = apiReturning((_) => http.Response('{}', 404));
      await expectLater(
        api.report(_report(ReportReason.other)),
        throwsA(
          isA<ReportApiException>()
              .having((e) => e.isRefused, 'isRefused', isTrue)
              .having((e) => e.isRetryable, 'isRetryable', isFalse),
        ),
      );
    });

    test('an entry the reader already reported reads as a duplicate', () async {
      final api = apiReturning((_) => http.Response('{}', 409));
      await expectLater(
        api.report(_report(ReportReason.other)),
        throwsA(
          isA<ReportApiException>()
              .having((e) => e.isDuplicate, 'isDuplicate', isTrue)
              .having((e) => e.isRetryable, 'isRetryable', isFalse),
        ),
      );
    });

    test('an unavailable store is retryable', () async {
      final api = apiReturning((_) => http.Response('{}', 503));
      await expectLater(
        api.report(_report(ReportReason.other)),
        throwsA(
          isA<ReportApiException>()
              .having((e) => e.isRetryable, 'isRetryable', isTrue)
              .having((e) => e.isDuplicate, 'isDuplicate', isFalse),
        ),
      );
    });

    test('a transport failure reads as the device being offline', () async {
      final api = HttpReportApi(
        baseUrl: 'https://gateway.scenova.app',
        idTokenProvider: () async => 'token',
        client: MockClient((_) async => throw http.ClientException('no route')),
      );

      await expectLater(
        api.report(_report(ReportReason.other)),
        throwsA(
          isA<ReportApiException>().having(
            (e) => e.isOffline,
            'isOffline',
            isTrue,
          ),
        ),
      );
    });

    test('an identity that cannot be read still sends the report', () async {
      late http.Request captured;
      final api = HttpReportApi(
        baseUrl: 'https://gateway.scenova.app',
        idTokenProvider: () async => throw StateError('no identity'),
        client: MockClient((request) async {
          captured = request;
          return http.Response('{"status":"queued"}', 202);
        }),
      );

      await api.report(_report(ReportReason.other));

      expect(captured.headers.containsKey('authorization'), isFalse);
    });
  });
}
