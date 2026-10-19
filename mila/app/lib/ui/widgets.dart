// Monospace building blocks: text glyphs, bracketed status labels, panels,
// key/value rows and console buttons. State is always text, weight or
// inverse video; never colour alone.
import 'package:flutter/material.dart';
import 'package:mila_core/mila_core.dart';

import 'theme.dart';
import 'tokens.dart';

/// Text glyphs, mirroring `MarshallWeb.CoreComponents` `@glyphs`. Icons are
/// characters JetBrains Mono renders in one cell; there is no icon font.
enum Glyph {
  arrowUpRight('↗'),
  arrowLeft('←'),
  arrowRight('→'),
  arrowUp('↑'),
  arrowDown('↓'),
  returnKey('↩'),
  refresh('↻'),
  check('■'),
  cross('×'),
  bullet('●'),
  circle('○'),
  square('□'),
  diamond('◆'),
  caretDown('▾'),
  caretRight('▸'),
  triangleRight('▶'),
  triangleDown('▼'),
  menu('≡'),
  plus('+'),
  minus('−'),
  bang('!'),
  info('i'),
  search('/'),
  copy('⎘'),
  home('⌂'),
  star('*');

  const Glyph(this.char);

  final String char;

  /// Whether the bundled JetBrains Mono draws this glyph. The web table
  /// includes two code points the font lacks (browsers fall back to another
  /// font); Mila never renders those, so every glyph stays one grid cell.
  bool get inFont => this != refresh && this != copy;
}

/// A glyph, decorative unless [label] names it for assistive technology.
class GlyphText extends StatelessWidget {
  const GlyphText(this.glyph, {super.key, this.label})
    : assert(glyph != Glyph.refresh && glyph != Glyph.copy, 'glyph is not in the bundled font');

  final Glyph glyph;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final text = Text(glyph.char, textDirection: TextDirection.ltr);
    return label == null ? ExcludeSemantics(child: text) : Semantics(label: label, child: text);
  }
}

/// A back arrow that points the way the reading direction goes back.
class BackGlyph extends StatelessWidget {
  const BackGlyph({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => GlyphText(
    Directionality.of(context) == TextDirection.rtl ? Glyph.arrowRight : Glyph.arrowLeft,
    label: label,
  );
}

/// `[label]`, styled by tone as `.status-label` is on the web.
class StatusLabel extends StatelessWidget {
  const StatusLabel(this.text, {super.key, this.tone});

  final String text;
  final StateTone? tone;

  @override
  Widget build(BuildContext context) {
    final tokens = MonoTheme.of(context);
    final base = DefaultTextStyle.of(context).style;
    final style = switch (tone) {
      StateTone.success => base.copyWith(fontWeight: MonoScale.bold),
      StateTone.pending => base.copyWith(fontStyle: FontStyle.italic, fontWeight: MonoScale.normal),
      StateTone.danger => base.copyWith(
        fontWeight: MonoScale.bold,
        color: tokens.background,
        backgroundColor: tokens.text,
      ),
      null => base,
    };
    final label = tone == StateTone.danger ? ' $text ' : text;
    return Text('[$label]', style: style, softWrap: false);
  }
}

/// A bordered box on the grid, optionally titled in its top border.
class Panel extends StatelessWidget {
  const Panel({super.key, this.title, required this.child});

  final String? title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = MonoTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: tokens.text, width: MonoScale.border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MonoScale.fontSize - MonoScale.border,
          vertical: MonoScale.line / 2 - MonoScale.border,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.only(bottom: MonoScale.line / 2),
                child: Text(
                  title!,
                  style: DefaultTextStyle.of(context).style.copyWith(fontWeight: MonoScale.bold),
                ),
              ),
            child,
          ],
        ),
      ),
    );
  }
}

/// A key/value row, as `<.kv>`.
class Kv extends StatelessWidget {
  const Kv(this.label, this.value, {super.key});

  final String label;
  final Widget value;

  @override
  Widget build(BuildContext context) {
    final tokens = MonoTheme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: MonoScale.fontSize * 8,
          child: Text(label, style: TextStyle(color: tokens.textAlt)),
        ),
        Expanded(child: value),
      ],
    );
  }
}

/// An uppercase console button with an optional leading glyph.
class ConsoleButton extends StatelessWidget {
  const ConsoleButton({super.key, required this.label, this.glyph, this.onPressed})
    : assert(glyph != Glyph.refresh && glyph != Glyph.copy, 'glyph is not in the bundled font');

  final String label;
  final Glyph? glyph;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: onPressed,
    child: Text(
      glyph == null ? label.toUpperCase() : '${glyph!.char} ${label.toUpperCase()}',
      softWrap: false,
    ),
  );
}

/// One choice among a few, as the web's segmented control: every option is
/// a bordered button and the selected one is drawn in inverse video, so the
/// selection never depends on colour alone.
class Segmented<T> extends StatelessWidget {
  const Segmented({
    super.key,
    required this.options,
    required this.selected,
    required this.label,
    this.onSelected,
    this.keyPrefix = 'segment',
  });

  final List<T> options;
  final T? selected;
  final String Function(T option) label;
  final ValueChanged<T>? onSelected;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final tokens = MonoTheme.of(context);
    return Wrap(
      children: [
        for (final (index, option) in options.indexed)
          Semantics(
            selected: option == selected,
            button: true,
            child: OutlinedButton(
              key: Key('$keyPrefix-$index'),
              style: option == selected
                  ? OutlinedButton.styleFrom(
                      backgroundColor: tokens.text,
                      foregroundColor: tokens.background,
                    )
                  : null,
              onPressed: onSelected == null ? null : () => onSelected!(option),
              child: Text(label(option).toUpperCase(), softWrap: false),
            ),
          ),
      ],
    );
  }
}

/// A row of page tabs under the app bar, as the web's top tabs.
class TopTabs extends StatelessWidget {
  const TopTabs({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelected,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final tokens = MonoTheme.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (index, label) in labels.indexed)
            Semantics(
              selected: index == selected,
              child: TextButton(
                key: Key('tab-$index'),
                style: index == selected
                    ? TextButton.styleFrom(
                        backgroundColor: tokens.text,
                        foregroundColor: tokens.background,
                      )
                    : null,
                onPressed: () => onSelected(index),
                child: Text(label.toUpperCase(), softWrap: false),
              ),
            ),
        ],
      ),
    );
  }
}
