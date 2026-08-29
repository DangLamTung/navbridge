import 'package:flutter_test/flutter_test.dart';

import 'package:navbridge/services/ai_assistant.dart';
import 'package:navbridge/services/voice_commands.dart';

void main() {
  test('AiContext.toPrompt builds a compact Vietnamese context block', () {
    const ctx = AiContext(
      position: '10.78, 106.65',
      road: 'Quốc lộ 1A (60 km/h)',
      speedKmh: '50 km/h',
      destination: 'Chợ Bến Thành',
      eta: '14:32',
      nextManeuver: 'rẽ trái vào Lê Lợi còn 300 m',
      cameraAhead: 'Camera tốc độ phía trước 500 m',
      weather: '30°C, mưa nhẹ',
    );
    final p = ctx.toPrompt();
    expect(p, contains('Ngữ cảnh hiện tại'));
    expect(p, contains('Vị trí: 10.78, 106.65'));
    expect(p, contains('Camera tốc độ phía trước 500 m'));
    expect(p, contains('30°C, mưa nhẹ'));
  });

  test('AiContext.toPrompt is empty when nothing is set', () {
    expect(const AiContext().toPrompt(), isEmpty);
  });

  test('parseVoiceCommand recognizes "hỏi AI …"', () {
    final c = parseVoiceCommand('hỏi ai xăng gần nhất');
    expect(c.type, VoiceCommandType.askAi);
    expect(c.query, 'xăng gần nhất');
  });

  test('parseVoiceCommand recognizes "hỏi trợ lý …"', () {
    final c = parseVoiceCommand('hỏi trợ lý thời tiết thế nào');
    expect(c.type, VoiceCommandType.askAi);
    expect(c.query, 'thời tiết thế nào');
  });

  test('parseVoiceCommand keeps normal commands unaffected', () {
    expect(
      parseVoiceCommand('chỉ đường tới chợ Bến Thành').type,
      VoiceCommandType.searchAndNavigate,
    );
    expect(parseVoiceCommand('dừng lại').type, VoiceCommandType.stop);
  });

  test('cleanPlaceQuery strips leading/trailing intent words', () {
    final a = AiAssistant.instance;
    expect(
      a.cleanPlaceQueryForTest('tìm quán phở Hùng gần đây'),
      'quán phở Hùng',
    );
    expect(
      a.cleanPlaceQueryForTest('khách sạn Vinpearl ở đâu'),
      'khách sạn Vinpearl',
    );
    expect(
      a.cleanPlaceQueryForTest('giúp tôi tìm cây xăng Petrolimex'),
      'cây xăng Petrolimex',
    );
    expect(a.cleanPlaceQueryForTest('siêu thị gần đây?'), 'siêu thị');
  });

  test('isNamedPlaceQuery detects name-search intents', () {
    final a = AiAssistant.instance;
    expect(a.isNamedPlaceQueryForTest('tìm quán phở Hùng'), isTrue);
    expect(a.isNamedPlaceQueryForTest('khách sạn Vinpearl ở đâu'), isTrue);
    expect(a.isNamedPlaceQueryForTest('thời tiết hôm nay thế nào'), isFalse);
    expect(a.isNamedPlaceQueryForTest('còn bao lâu tới nơi'), isFalse);
  });

  test('shouldWebSearch skips greetings and drive-context questions', () {
    final a = AiAssistant.instance;
    expect(a.shouldWebSearchForTest('giá xăng hôm nay bao nhiêu'), isTrue);
    expect(a.shouldWebSearchForTest('lễ hội đèn lồng Hội An tháng 9'), isTrue);
    // Relaxed skips: traffic / speed-limit / đèo / route questions DO web-search.
    expect(a.shouldWebSearchForTest('cao tốc nào đang kẹt xe'), isTrue);
    expect(a.shouldWebSearchForTest('tốc độ tối đa trên QL1A'), isTrue);
    // Still skipped: greetings + live nav-state + current weather.
    expect(a.shouldWebSearchForTest('chào bạn'), isFalse);
    expect(a.shouldWebSearchForTest('còn bao lâu tới nơi'), isFalse);
    expect(a.shouldWebSearchForTest('thời tiết hiện tại thế nào'), isFalse);
    expect(
      a.shouldWebSearchForTest('trạm dừng tiếp theo cách bao xa'),
      isFalse,
    );
  });

  test('isGasPriceQuery detects price questions, not station-finding', () {
    final a = AiAssistant.instance;
    expect(a.isGasPriceQueryForTest('giá xăng hôm nay bao nhiêu'), isTrue);
    expect(a.isGasPriceQueryForTest('giá xăng dầu hôm nay'), isTrue);
    expect(a.isGasPriceQueryForTest('xăng bao nhiêu 1 lít'), isTrue);
    expect(a.isGasPriceQueryForTest('tìm trạm xăng gần nhất'), isFalse);
    expect(a.isGasPriceQueryForTest('trạm xăng gần đây ở đâu'), isFalse);
  });

  test('cleanWebQuery strips question fillers', () {
    final a = AiAssistant.instance;
    expect(
      a.cleanWebQueryForTest('giá xăng hôm nay bao nhiêu?'),
      'giá xăng hôm nay',
    );
    expect(
      a.cleanWebQueryForTest('thời tiết Hà Nội mai thế nào?'),
      'thời tiết Hà Nội mai thế nào',
    );
  });
}
