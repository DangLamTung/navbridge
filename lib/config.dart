/// App configuration — everything overridable at build time:
///
///   flutter run --dart-define=VIETMAP_API_KEY=YOUR_KEY --dart-define=CLOCK_MAC=12:34:...
///
/// or edit the defaults below.
class AppConfig {
  // Optional: the clock's BLE address. When empty the app scans for a device
  // advertising the E-ink service or with "EINK" in its name.
  // The DA14585 only advertises periodically, so connecting by MAC (direct
  // GATT connect) is far more reliable. MAC from the vendor app's logs.
  static const String clockMac = String.fromEnvironment('CLOCK_MAC',
      defaultValue: '18:BC:5A:80:AD:ED');

  // --- E-ink clock BLE GATT profile (see firmware/PROTOCOL.md) ---
  static const String serviceUuid = 'afdbecdd-1234-abcd-2007-aabbccddeeff';
  static const String writeCharUuid = '772ae377-b3d2-4f8e-4042-5481d121199c';
  static const String indicateCharUuid =
      '9e1547ba-c365-57b5-2947-c5e1c1e1d528';

  // Auth handshake: MAC registration header (30 bytes, caught from the real
  // tablet) then the key string.
  static const List<int> macHeader = [
    0x18, 0xBC, 0x5A, 0x80, 0xAD, 0xED, 0, 0, 0, 0, 0, 1, 10, 0, 0, 0, 0, 80,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0,
  ];
  static const String authKey = 'I47T_EINK_KEY';
}
