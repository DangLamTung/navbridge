/// Tests for the Vietnamese/English voice command parser
/// (`voice_commands.dart`).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/voice_commands.dart';

void main() {
  group('parseVoiceCommand', () {
    test('search + auto-navigate (Vietnamese)', () {
      final c = parseVoiceCommand('chỉ đường tới chợ Bến Thành');
      expect(c.type, VoiceCommandType.searchAndNavigate);
      // The parser lowercases the whole utterance, so the query is lowercase.
      expect(c.query, 'chợ bến thành');
      expect(c.navigate, isTrue);
    });

    test('search + auto-navigate (English)', () {
      final c = parseVoiceCommand('navigate to Ben Thanh');
      expect(c.type, VoiceCommandType.searchAndNavigate);
      expect(c.query, 'ben thanh');
      expect(c.navigate, isTrue);
    });

    test('plain search does not auto-navigate', () {
      final c = parseVoiceCommand('tìm quán cà phê');
      expect(c.type, VoiceCommandType.searchAndNavigate);
      expect(c.query, 'quán cà phê');
      expect(c.navigate, isFalse);
    });

    test('start / stop', () {
      expect(parseVoiceCommand('bắt đầu').type, VoiceCommandType.start);
      expect(parseVoiceCommand('đi thôi').type, VoiceCommandType.start);
      expect(parseVoiceCommand('start').type, VoiceCommandType.start);
      expect(parseVoiceCommand('dừng lại').type, VoiceCommandType.stop);
      expect(parseVoiceCommand('kết thúc').type, VoiceCommandType.stop);
      expect(parseVoiceCommand('cancel').type, VoiceCommandType.stop);
    });

    test('zoom', () {
      expect(
        parseVoiceCommand('phóng to bản đồ').type,
        VoiceCommandType.zoomIn,
      );
      expect(parseVoiceCommand('zoom in').type, VoiceCommandType.zoomIn);
      expect(parseVoiceCommand('thu nhỏ').type, VoiceCommandType.zoomOut);
      expect(parseVoiceCommand('zoom out').type, VoiceCommandType.zoomOut);
    });

    test('voice toggles and help', () {
      expect(parseVoiceCommand('tắt tiếng').type, VoiceCommandType.voiceOff);
      expect(parseVoiceCommand('bật tiếng').type, VoiceCommandType.voiceOn);
      expect(parseVoiceCommand('unmute').type, VoiceCommandType.voiceOn);
      expect(parseVoiceCommand('giúp tôi').type, VoiceCommandType.help);
      expect(parseVoiceCommand('help').type, VoiceCommandType.help);
    });

    test('always-on wake-word toggles', () {
      expect(
        parseVoiceCommand('bật nghe luôn').type,
        VoiceCommandType.alwaysOnOn,
      );
      expect(
        parseVoiceCommand('nghe liên tục').type,
        VoiceCommandType.alwaysOnOn,
      );
      expect(
        parseVoiceCommand('tắt nghe luôn').type,
        VoiceCommandType.alwaysOnOff,
      );
      expect(parseVoiceCommand('dừng nghe').type, VoiceCommandType.alwaysOnOff);
    });

    test('empty and unknown input map to none', () {
      expect(parseVoiceCommand('').type, VoiceCommandType.none);
      expect(parseVoiceCommand('   ').type, VoiceCommandType.none);
      expect(parseVoiceCommand('xyz abc').type, VoiceCommandType.none);
    });

    test('ask AI — diacritic-insensitive + polite prefixes', () {
      expect(
        parseVoiceCommand('hỏi AI trạm xăng gần nhất').type,
        VoiceCommandType.askAi,
      );
      expect(
        parseVoiceCommand('hỏi trợ lý còn bao nhiêu camera').type,
        VoiceCommandType.askAi,
      );
      // Recognizer drops diacritics (only the query keeps the original).
      final d = parseVoiceCommand('hoi ai con bao nhieu camera');
      expect(d.type, VoiceCommandType.askAi);
      expect(d.query, 'con bao nhieu camera');
      // Polite leading phrase even when diacritics are dropped.
      final c = parseVoiceCommand('cho tôi hỏi AI bao giờ hết đèo');
      expect(c.type, VoiceCommandType.askAi);
      expect(c.query, 'bao giờ hết đèo');
      final e = parseVoiceCommand('xin hoi tro ly trang duong co xang khong');
      expect(e.type, VoiceCommandType.askAi);
      expect(e.query, 'trang duong co xang khong');
    });
  });
}
