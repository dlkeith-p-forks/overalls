import 'package:mila_build/native_strings.dart';
import 'package:test/test.dart';

void main() {
  test('catalog file names map to BCP 47 tags', () {
    expect(localeOf('app_en.arb'), 'en');
    expect(localeOf('app_pt_BR.arb'), 'pt-BR');
    expect(localeOf('app_zh_Hans.arb'), 'zh-Hans');
    expect(localeOf('app_localizations.dart'), isNull);
    expect(localeOf('app_EN.arb'), isNull);
  });

  test('a catalog yields its fixed notification text', () {
    final text = readCatalog(
      'en',
      '{"pushNeedsInputTitle": "An agent needs your input", "pushNeedsInputBody": "Open Mila."}',
    );
    expect(text.title, 'An agent needs your input');
    expect(text.body, 'Open Mila.');
  });

  test('missing, empty, placeholder or non-string messages are refused', () {
    for (final contents in [
      '{"pushNeedsInputTitle": "T"}',
      '{"pushNeedsInputTitle": "", "pushNeedsInputBody": "B"}',
      '{"pushNeedsInputTitle": "Hi {name}", "pushNeedsInputBody": "B"}',
      '{"pushNeedsInputTitle": 1, "pushNeedsInputBody": "B"}',
      '[]',
      'not json',
    ]) {
      expect(() => readCatalog('xx', contents), throwsA(isA<CatalogError>()), reason: contents);
    }
  });

  test('wide literals are ASCII with escapes for quotes and non-ASCII', () {
    expect(wideLiteral('a "b" \\'), r'L"a \"b\" \\"');
    expect(wideLiteral('ردّ'), r'L"\u0631\u062f\u0651"');
    expect(wideLiteral('😀'), r'L"\U0001f600"');
    expect(wideLiteral('a\nb'), r'L"a\u000ab"');
  });

  test('the header is sorted, stable and needs English', () {
    const de = NotificationText(locale: 'de', title: 'T', body: 'B');
    const en = NotificationText(locale: 'en', title: 'Title', body: 'Body');
    final header = renderHeader([en, de]);
    expect(header, renderHeader([de, en]));
    expect(header.indexOf('L"de"'), lessThan(header.indexOf('L"en"')));
    expect(header, contains('{L"en", L"Title", L"Body"},'));
    expect(header.codeUnits.every((c) => c < 0x80), isTrue);
    expect(() => renderHeader([de]), throwsA(isA<CatalogError>()));
  });
}
