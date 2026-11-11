import 'package:flutter_test/flutter_test.dart';
import 'package:smartheritage/features/visit_history/visit_history_screen.dart';

void main() {
  test('visitDayLabel groups records by local calendar date', () {
    final first = {'detectedAt': '2026-11-11T08:05:00'};
    final later = {'detectedAt': '2026-11-11T19:40:00'};
    final nextDay = {'detectedAt': '2026-11-12T09:00:00'};

    expect(visitDayLabel(first), 'Ngày 11/11/2026');
    expect(visitDayLabel(later), visitDayLabel(first));
    expect(visitDayLabel(nextDay), 'Ngày 12/11/2026');
  });

  test('visitDayLabel handles missing timestamp and legacy visitedAt', () {
    expect(visitDayLabel({}), 'Không rõ ngày');
    expect(visitDayLabel({'detectedAt': 'invalid'}), 'Không rõ ngày');
    expect(visitDayLabel({'visitedAt': '2026-11-09T10:00:00'}), 'Ngày 09/11/2026');
  });
}
