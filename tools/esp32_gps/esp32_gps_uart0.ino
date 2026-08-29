/*
 * NavBridge — ESP32 GPS bridge: NMEA from UART0 (TX0/RX0) → BLE NOTIFY
 * ==================================================================
 * Reads a serial GPS module (NEO-6M / NEO-8M / ATGM336H, 9600 8N1) on
 * UART0 (TX0 = GPIO1, RX0 = GPIO3) and forwards every complete NMEA line
 * (starting with '$') to the NavBridge phone app over BLE, using the
 * NAV-OSM nav characteristic's NOTIFY.
 *
 * The phone side ALREADY listens for this — lib/services/ble_map_clock.dart
 * subscribes to NOTIFY on 5a7e1001-… and routes any value starting with '$'
 * to `gpsNmeaStream`. So no app change is needed to receive the raw NMEA.
 *
 *   ┌──────────────┐  UART0 @9600  ┌─────────────────────────┐ BLE NOTIFY ┌──────────────┐
 *   │  GPS module  │ ── TX0/RX0 ─► │ ESP32 (this sketch)     │ ─────────► │ NavBridge app│
 *   │ (NEO-6M/8M)  │               │ UART0=GPS  UART1=debug  │            │ gpsNmeaStream│
 *   └──────────────┘               └─────────────────────────┘            └──────────────┘
 *
 * WIRING  (GPS module ↔ ESP32):
 *     GPS  TX  → ESP32 RX0 (GPIO3)
 *     GPS  RX  → ESP32 TX0 (GPIO1)
 *     GPS  VCC → 3.3 V (or 5 V only if the module has an onboard regulator)
 *     GPS  GND → GND
 *
 * ⚠ UART0 / flashing caveat:
 *   On most ESP32 dev boards, UART0 doubles as the USB-serial port used to
 *   FLASH the chip and for the Serial Monitor. With the GPS on UART0:
 *     - Never print debug to `Serial` (it would transmit into the GPS).
 *       Debug output here goes to `Serial1` (GPIO17 TX / GPIO16 RX).
 *     - The ROM bootloader also listens on UART0. If flashing hangs or
 *       fails, briefly disconnect GPS TX from RX0 (or the GPS's VCC) while
 *       flashing, then reconnect and reboot.
 *
 * TO TEST with the app:
 *   1. Flash this sketch (Board: ESP32 dev module).
 *   2. Open NavBridge → Settings → Bluetooth auto-connect → scan; the
 *      board appears as "NAV-OSM".
 *   3. Watch logcat: `[MAP] subscribed to GPS NMEA notify` and the NMEA
 *      lines will land in `gpsNmeaStream` (app side, ready for the next
 *      step of parsing them into a position source).
 */

#include <NimBLEDevice.h>

// ---- GATT profile — MUST mirror lib/core/map_protocol.dart ----
static const char *SERVICE_UUID   = "5a7e1000-2b2f-4f66-9f9a-5c0f8e1a2b3c";
static const char *NAV_CHAR_UUID  = "5a7e1001-2b2f-4f66-9f9a-5c0f8e1a2b3c";
static const char *DEVICE_NAME    = "NAV-OSM";

// ---- UARTs ----
#define GPS_BAUD     9600        // NEO-6M/8M / ATGM336H default
#define GPS_UART_NUM 0           // UART0 (TX0 = GPIO1, RX0 = GPIO3)
#define GPS_TX_PIN   1
#define GPS_RX_PIN   3
#define DBG_UART_NUM 1           // debug on Serial1 (TX=GPIO17, RX=GPIO16)
#define DBG_TX_PIN   17
#define DBG_RX_PIN   16

#define NMEA_MAX     120         // longest standard NMEA line ~82 B; leave room
#define NMEA_FILTER  0           // 0 = forward ALL '$' sentences; 1 = RMC+GGA only

static NimBLECharacteristic *s_navChar = nullptr;
static char s_line[NMEA_MAX];
static size_t s_lineLen = 0;

// Debug to Serial1 (never Serial — that's the GPS on UART0).
static void dbg(const char *msg) {
  if (DBG_UART_NUM == 1) { Serial1.print("[GPS-BRIDGE] "); Serial1.println(msg); }
}

// ---- BLE write callback (phone → ESP binary frames). Not used by the
//      GPS bridge, but keep the char writable so the phone can also send
//      route/pos/nav frames to the same char in the merged firmware. ----
class NavCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *c) override {
    (void)c; // ignore payload in this standalone bridge sketch
  }
};

void setup() {
  // Debug on UART1 — UART0 belongs to the GPS.
  Serial1.begin(115200, SERIAL_8N1, DBG_RX_PIN, DBG_TX_PIN);
  dbg("boot — GPS on UART0 @9600, debug on Serial1");

  // GPS on UART0: begin(baud, config, RX_pin, TX_pin).
  Serial.begin(GPS_BAUD, SERIAL_8N1, GPS_RX_PIN, GPS_TX_PIN);

  // ---- BLE server (NimBLE) ----
  NimBLEDevice::init(DEVICE_NAME);
  NimBLEDevice::setMTU(256);                 // NMEA lines (~80 B) fit in one notify
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);    // +9 dBm — reachable from a helmet phone

  NimBLEServer *server = NimBLEDevice::createServer();
  server->advertiseOnDisconnect(true);

  NimBLEService *svc = server->createService(SERVICE_UUID);
  s_navChar = svc->createCharacteristic(
      NAV_CHAR_UUID,
      NIMBLE_PROPERTY::WRITE |
      NIMBLE_PROPERTY::WRITE_NR |
      NIMBLE_PROPERTY::NOTIFY);
  s_navChar->setCallbacks(new NavCallbacks());
  svc->start();

  // Advertise the service UUID (the app matches on it for auto-connect)
  // + the name so the picker shows "NAV-OSM".
  NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  adv->start();

  dbg("BLE up — service advertised, waiting for the app...");
}

void loop() {
  // Drain UART0 into a line buffer; forward complete '$' lines via NOTIFY.
  while (Serial.available()) {
    char c = (char)Serial.read();

    if (c == '\n') {
      // Trim trailing '\r' (u-blox sends CRLF).
      if (s_lineLen > 0 && s_line[s_lineLen - 1] == '\r') s_lineLen--;

      if (s_lineLen > 0 && s_line[0] == '$') {
        bool fwd = true;
#if NMEA_FILTER
        fwd = (strncmp(s_line, "$GPRMC", 6) == 0 ||
               strncmp(s_line, "$GNRMC", 6) == 0 ||
               strncmp(s_line, "$GPGGA", 6) == 0 ||
               strncmp(s_line, "$GNGGA", 6) == 0);
#endif
        if (fwd && s_navChar != nullptr && s_navChar->getSubscribedCount() > 0) {
          s_navChar->setValue((uint8_t *)s_line, s_lineLen);
          s_navChar->notify();
          if (DBG_UART_NUM == 1) { Serial1.write(s_line, s_lineLen); Serial1.println(); }
        }
      }
      s_lineLen = 0;
    } else if (s_lineLen < NMEA_MAX - 1) {
      s_line[s_lineLen++] = c;
    } else {
      s_lineLen = 0; // overflow — drop the line and resync
    }
  }
}
