import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';

/// The shared Word and Phrase Header (`docs/Scenova/screens.md`).
///
/// The target word as a heading with the gloss phrase beneath it. The phrase is
/// shown while a clip generates or when no clip is available, and any
/// reader-facing advisory the service sends travels in [note] — including the
/// best-guess note, which is a notice and never a sense-label signal. A very
/// long word wraps to two lines and then truncates.
class WordPhraseHeader extends StatelessWidget {
  const WordPhraseHeader({
    super.key,
    required this.word,
    this.phrase,
    this.note,
    this.textAlign = TextAlign.start,
    this.compact = false,
  });

  final String word;
  final String? phrase;
  final String? note;
  final TextAlign textAlign;

  /// The caption treatment, used under the clip where the word is repeated
  /// beneath its own heading.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final crossAxis = textAlign == TextAlign.center
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;

    final wordStyle = compact
        ? styles.caption.copyWith(color: colors.textSecondary)
        : styles.h3.copyWith(color: colors.textPrimary);
    final phraseStyle = compact
        ? styles.body.copyWith(color: colors.textPrimary)
        : styles.bodyLarge.copyWith(color: colors.textSecondary);

    return Column(
      crossAxisAlignment: crossAxis,
      children: <Widget>[
        Semantics(
          header: !compact,
          child: Text(
            word,
            style: wordStyle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: textAlign,
          ),
        ),
        if (phrase != null && phrase!.isNotEmpty) ...<Widget>[
          SizedBox(height: tokens.spacing.xs),
          Text(phrase!, style: phraseStyle, textAlign: textAlign),
        ],
        if (note != null) ...<Widget>[
          SizedBox(height: tokens.spacing.sm),
          Text(
            note!,
            style: styles.bodySmall.copyWith(color: colors.textSecondary),
            textAlign: textAlign,
          ),
        ],
      ],
    );
  }
}
