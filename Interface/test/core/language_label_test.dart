import 'package:flutter_test/flutter_test.dart';
import 'package:smartheritage/core/artifact_service.dart';

void main() {
  test('content language labels do not misidentify extra languages as English', () {
    expect(const ArtifactContentItem(languageCode: 'vi').languageLabel,
        '🇻🇳 Tiếng Việt');
    expect(const ArtifactContentItem(languageCode: 'en').languageLabel,
        '🇬🇧 English');
    expect(const ArtifactContentItem(languageCode: 'fr').languageLabel, 'FR');
    expect(const ArtifactContentItem(languageCode: 'ja').languageLabel, 'JA');
  });
}
