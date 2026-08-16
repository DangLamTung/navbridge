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
}
