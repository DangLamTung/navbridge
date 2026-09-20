/// Tests for the Vietnamese/English voice command parser
/// (`voice_commands.dart`).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/offline_tiles.dart' show wakeWord;
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

    test('empty input maps to none', () {
      expect(parseVoiceCommand('').type, VoiceCommandType.none);
      expect(parseVoiceCommand('   ').type, VoiceCommandType.none);
    });

    // The user: "the voice is too strict — thing like đường đến, or just tell
    // the location should start the navigation". A bare place name is now a
    // destination; the caller searches it and reports when nothing matches.
    test('bare place name auto-navigates', () {
      for (final phrase in [
        'chợ bến thành',
        'sân bay tân sơn nhất',
        'đường nguyễn trãi',
        'xyz abc',
      ]) {
        final c = parseVoiceCommand(phrase);
        expect(c.type, VoiceCommandType.searchAndNavigate, reason: phrase);
        expect(c.navigate, isTrue, reason: phrase);
        expect(c.query, phrase, reason: phrase);
      }
    });

    test('natural "đường đến / dẫn đường / đến / đi" phrasings navigate', () {
      final cases = <String, String>{
        'đường đến chợ bến thành': 'chợ bến thành',
        'đường tới sân bay': 'sân bay',
        'dẫn đường về đà lạt': 'đà lạt',
        'dẫn đường tới vũng tàu': 'vũng tàu',
        'tìm đường đến cần thơ': 'cần thơ',
        'đến vũng tàu': 'vũng tàu',
        'tới đà lạt': 'đà lạt',
        'đi đà nẵng': 'đà nẵng',
        // The recognizer drops diacritics all the time.
        'chi duong toi ben thanh': 'ben thanh',
        'duong den vung tau': 'vung tau',
      };
      for (final e in cases.entries) {
        final c = parseVoiceCommand(e.key);
        expect(c.type, VoiceCommandType.searchAndNavigate, reason: e.key);
        expect(c.navigate, isTrue, reason: e.key);
        expect(c.query, e.value, reason: e.key);
      }
    });

    test('questions and control words never become a destination', () {
      // Questions stay with the AI / unknown path.
      expect(parseVoiceCommand('thời tiết thế nào').type, isNot(
        VoiceCommandType.searchAndNavigate));
      expect(parseVoiceCommand('còn bao nhiêu km').type, isNot(
        VoiceCommandType.searchAndNavigate));
      // Control phrases still win over the bare-place fallback.
      expect(parseVoiceCommand('đi thôi').type, VoiceCommandType.start);
      expect(parseVoiceCommand('dừng lại').type, VoiceCommandType.stop);
      expect(parseVoiceCommand('tắt tiếng').type, VoiceCommandType.voiceOff);
      expect(parseVoiceCommand('phóng to').type, VoiceCommandType.zoomIn);
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

  group('VoiceCommands.wakeCommand', () {
    test('extracts command with preserved spaces and diacritics', () {
      final cmd1 = VoiceCommands.wakeCommand('dậy đi tìm cây xăng');
      expect(cmd1, 'tìm cây xăng');

      final cmd2 = VoiceCommands.wakeCommand('Dậy đi, chỉ đường tới chợ Bến Thành');
      expect(cmd2, 'chỉ đường tới chợ Bến Thành');

      final cmd3 = VoiceCommands.wakeCommand('day di, phong to ban do');
      expect(cmd3, 'phong to ban do');
    });

    test('returns empty string when only wake word is spoken', () {
      expect(VoiceCommands.wakeCommand('dậy đi'), '');
      expect(VoiceCommands.wakeCommand('day di'), '');
    });

    test('supports custom wakeWord and diacritic-insensitive matching', () {
      final old = wakeWord;
      addTearDown(() => wakeWord = old);

      wakeWord = 'trợ lý ơi';
      expect(
        VoiceCommands.wakeCommand('trợ lý ơi: cho tôi hỏi AI thời tiết hôm nay'),
        'cho tôi hỏi AI thời tiết hôm nay',
      );
      expect(VoiceCommands.wakeCommand('tro ly oi'), '');

      wakeWord = 'navbridge';
      expect(VoiceCommands.wakeCommand('navbridge'), '');
      expect(VoiceCommands.wakeCommand('navbridge phong to'), 'phong to');
    });

    test('returns null when wake word is absent or not at beginning', () {
      expect(VoiceCommands.wakeCommand('tìm cây xăng'), isNull);
      expect(VoiceCommands.wakeCommand('tôi nói dậy đi mà'), isNull);
      expect(VoiceCommands.wakeCommand(''), isNull);
    });
  });
}
