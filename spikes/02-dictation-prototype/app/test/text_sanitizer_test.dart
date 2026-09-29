import 'package:flutter_test/flutter_test.dart';
import 'package:app/text_sanitizer.dart';

void main() {
  group('TextSanitizer.sanitizeRepetitions', () {
    test('handles empty or whitespace strings', () {
      expect(TextSanitizer.sanitizeRepetitions(''), '');
      expect(TextSanitizer.sanitizeRepetitions('   '), '');
    });

    test('preserves normal non-repeating sentences', () {
      const input = 'This is a normal sentence with no runaway loops.';
      expect(TextSanitizer.sanitizeRepetitions(input), input);
    });

    test('preserves legitimate double words (up to maxRepeats)', () {
      const input = 'That that is is that that is not is not.';
      expect(TextSanitizer.sanitizeRepetitions(input, maxRepeats: 2), input);
    });

    test('collapses consecutive single word loops', () {
      const input = 'testing testing testing testing testing';
      expect(
        TextSanitizer.sanitizeRepetitions(input, maxRepeats: 2),
        'testing testing',
      );
    });

    test('collapses runaway single word loops with punctuation', () {
      const input = 'testing, testing! testing... testing? testing.';
      expect(
        TextSanitizer.sanitizeRepetitions(input, maxRepeats: 2),
        'testing, testing!',
      );
    });

    test('collapses multi-word phrase loops (n-grams)', () {
      const input = 'I think so. I think so. I think so. I think so.';
      expect(
        TextSanitizer.sanitizeRepetitions(input, maxRepeats: 2),
        'I think so. I think so.',
      );
    });

    test('collapses longer repetitive loops while keeping prefix and suffix', () {
      const input =
          'Hello everyone. Thank you thank you thank you thank you for listening.';
      expect(
        TextSanitizer.sanitizeRepetitions(input, maxRepeats: 2),
        'Hello everyone. Thank you thank you for listening.',
      );
    });

    test('collapses loops with maxRepeats=1 when requested', () {
      const input = 'echo echo echo echo';
      expect(
        TextSanitizer.sanitizeRepetitions(input, maxRepeats: 1),
        'echo',
      );
    });
  });
}
