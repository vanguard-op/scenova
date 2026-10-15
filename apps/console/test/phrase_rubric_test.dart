import 'package:flutter_test/flutter_test.dart';
import 'package:scenova_console/models/phrase_rubric.dart';

void main() {
  group('phraseRubricError', () {
    test('refuses an empty phrase', () {
      expect(phraseRubricError(''), isNotNull);
      expect(phraseRubricError('   '), isNotNull);
    });

    test('accepts a phrase of seven words or fewer', () {
      expect(phraseRubricError('a river bank'), isNull);
      expect(phraseRubricError('one two three four five six seven'), isNull);
    });

    test('refuses a phrase over seven words', () {
      expect(
        phraseRubricError('one two three four five six seven eight'),
        'Keep the phrase to 7 words or fewer.',
      );
    });

    test('refuses a phrase over the service\'s length bound', () {
      expect(
        phraseRubricError('a' * (maxPhraseLength + 1)),
        'Keep the phrase to 60 characters or fewer.',
      );
      expect(phraseRubricError('a' * maxPhraseLength), isNull);
    });

    test('judges the phrase trimmed, so stray space never fails it', () {
      expect(phraseRubricError('  a river bank  '), isNull);
    });
  });
}
