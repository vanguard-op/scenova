import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/lookup.dart';
import 'package:scenova/services/capture_intake.dart';

void main() {
  group('CaptureSelection.parse', () {
    test('treats a null selection as empty and starts no lookup', () {
      final selection = CaptureSelection.parse(null);
      expect(selection.isEmpty, isTrue);
      expect(selection.kind, isNull);
      expect(selection.text, isEmpty);
    });

    test('treats whitespace-only as empty', () {
      expect(CaptureSelection.parse('   \n\t ').isEmpty, isTrue);
    });

    test('treats punctuation-only as empty', () {
      expect(CaptureSelection.parse(' —…!? ').isEmpty, isTrue);
    });

    test('resolves a single word as a word lookup', () {
      final selection = CaptureSelection.parse('coming');
      expect(selection.isEmpty, isFalse);
      expect(selection.kind, LookupKind.word);
      expect(selection.text, 'coming');
      expect(selection.overLimit, isFalse);
    });

    test('trims trailing punctuation before the lookup', () {
      expect(CaptureSelection.parse('coming,').text, 'coming');
      expect(CaptureSelection.parse('  “coming!”  ').text, 'coming');
      expect(CaptureSelection.parse('(coming).').text, 'coming');
    });

    test('keeps a hyphenated compound as one word', () {
      final selection = CaptureSelection.parse('well-known');
      expect(selection.text, 'well-known');
      expect(selection.kind, LookupKind.word);
    });

    test('resolves two to six words as a short phrase', () {
      final selection = CaptureSelection.parse('once in a while');
      expect(selection.kind, LookupKind.phrase);
      expect(selection.wordCount, 4);
      expect(selection.overLimit, isFalse);
    });

    test('keeps a six-word selection as a phrase within the limit', () {
      final selection = CaptureSelection.parse(
        'the quick brown fox jumps over',
      );
      expect(selection.overLimit, isFalse);
      expect(selection.wordCount, 6);
      expect(selection.kind, LookupKind.phrase);
    });

    test('keeps a selection over six words within the limit and notices', () {
      final selection = CaptureSelection.parse(
        'the quick brown fox jumps over the lazy dog',
      );
      expect(selection.overLimit, isTrue);
      expect(selection.limit, SelectionLimit.words);
      expect(selection.truncatedFrom, 9);
      expect(selection.wordCount, kMaxSelectionWords);
      expect(selection.text, 'the quick brown fox jumps over');
      expect(selection.text.length, lessThanOrEqualTo(kMaxSelectionCharacters));
      expect(selection.notice, CaptureSelection.overLimitNotice);
    });

    test('collapses runs of whitespace before counting words', () {
      final selection = CaptureSelection.parse('  give   up  ');
      expect(selection.text, 'give up');
      expect(selection.wordCount, 2);
    });
  });

  group('CaptureSelection.parse and the character bound', () {
    // Six words, but well over eighty characters.
    const longPhrase =
        'antidisestablishmentarianism antidisestablishmentarianism '
        'antidisestablishmentarianism antidisestablishmentarianism '
        'antidisestablishmentarianism antidisestablishmentarianism';

    test('keeps a long phrase within the bound and notices', () {
      final selection = CaptureSelection.parse(longPhrase);
      expect(selection.overLimit, isTrue);
      expect(selection.limit, SelectionLimit.characters);
      expect(selection.text.length, lessThanOrEqualTo(kMaxSelectionCharacters));
      expect(selection.notice, CaptureSelection.tooLongNotice);
    });

    test('drops a whole word rather than cutting one in half', () {
      final selection = CaptureSelection.parse(
        'antidisestablishmentarianism antidisestablishmentarianism '
        'antidisestablishmentarianism',
      );
      expect(
        selection.text,
        'antidisestablishmentarianism '
        'antidisestablishmentarianism',
      );
      expect(selection.text.length, lessThanOrEqualTo(kMaxSelectionCharacters));
      expect(selection.wordCount, 2);
    });

    test('cuts a lone word longer than the bound', () {
      final selection = CaptureSelection.parse('a' * 120);
      expect(selection.overLimit, isTrue);
      expect(selection.limit, SelectionLimit.characters);
      expect(selection.text.length, kMaxSelectionCharacters);
    });

    test('leaves a selection at exactly the bound alone', () {
      final text = 'a' * kMaxSelectionCharacters;
      final selection = CaptureSelection.parse(text);
      expect(selection.overLimit, isFalse);
      expect(selection.limit, SelectionLimit.none);
      expect(selection.text, text);
    });

    test('names the word limit when a selection is over both', () {
      final selection = CaptureSelection.parse('$longPhrase and more');
      expect(selection.limit, SelectionLimit.words);
      expect(selection.notice, CaptureSelection.overLimitNotice);
      expect(selection.text.length, lessThanOrEqualTo(kMaxSelectionCharacters));
    });
  });
}
