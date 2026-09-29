/// Utility to clean and sanitize transcribed text from whisper decoder loops
/// and runaway repetitions.
class TextSanitizer {
  /// Collapses runaway consecutive repetitions of words or n-grams.
  ///
  /// Examples:
  /// - "testing testing testing testing" -> "testing"
  /// - "I think so. I think so. I think so." -> "I think so."
  ///
  /// [maxConsecutiveRepeats] is the maximum number of times an n-gram or word
  /// may appear consecutively before being truncated/collapsed (default 2, meaning
  /// 3+ consecutive occurrences get collapsed to [maxConsecutiveRepeats] or 1).
  static String sanitizeRepetitions(
    String input, {
    int maxRepeats = 2,
    int maxNgramWords = 8,
  }) {
    if (input.trim().isEmpty) return input.trim();

    String current = input;

    // 1. Collapse word-level loops (punctuation-insensitive or exact)
    // E.g. "testing testing testing..." or "yeah, yeah, yeah, yeah"
    current = _collapseRepeatedNgrams(
      current,
      maxRepeats: maxRepeats,
      maxNgramWords: maxNgramWords,
    );

    return current.trim();
  }

  static String _collapseRepeatedNgrams(
    String text, {
    required int maxRepeats,
    required int maxNgramWords,
  }) {
    // Tokenize text keeping track of whitespace/punctuation or split by spaces
    final rawTokens = text.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (rawTokens.length <= maxRepeats) return text;

    // Clean tokens for comparison (lowercase, strip trailing punctuation)
    final normalized = rawTokens
        .map((t) => t.toLowerCase().replaceAll(RegExp(r'^[^\w]+|[^\w]+$'), ''))
        .toList();

    var n = rawTokens.length;
    var modified = false;
    final keptRawTokens = List<String>.from(rawTokens);
    final keptNormalized = List<String>.from(normalized);

    // Check n-gram sizes from maxNgramWords down to 1
    for (var k = min(maxNgramWords, n ~/ (maxRepeats + 1)); k >= 1; k--) {
      var i = 0;
      while (i + k <= keptNormalized.length) {
        final ngramNorm = keptNormalized.sublist(i, i + k).join(' ');
        if (ngramNorm.isEmpty) {
          i++;
          continue;
        }

        var repeats = 1;
        var nextIdx = i + k;
        while (nextIdx + k <= keptNormalized.length) {
          final nextNgram = keptNormalized.sublist(nextIdx, nextIdx + k).join(' ');
          if (nextNgram == ngramNorm) {
            repeats++;
            nextIdx += k;
          } else {
            break;
          }
        }

        if (repeats > maxRepeats) {
          // Collapse runaway loop down to maxRepeats
          final removeStart = i + (k * maxRepeats);
          final removeCount = (repeats - maxRepeats) * k;
          keptRawTokens.removeRange(removeStart, removeStart + removeCount);
          keptNormalized.removeRange(removeStart, removeStart + removeCount);
          modified = true;
          // Continue scanning from after the preserved ngrams
          i += k * maxRepeats;
        } else {
          i++;
        }
      }
    }

    if (!modified) return text;
    return keptRawTokens.join(' ');
  }

  static int min(int a, int b) => a < b ? a : b;
}
