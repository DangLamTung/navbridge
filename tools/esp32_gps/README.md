# ESP32 GPS bridge (UART0 → BLE NMEA)

Standalone Arduino/NimBLE sketch that reads a serial GPS module on **UART0
(TX0 = GPIO1, RX0 = GPIO3)** and forwards every complete NMEA line to the
NavBridge phone app over BLE, using the existing NAV-OSM GATT profile — **no
app change needed** to receive the raw NMEA (`gpsNmeaStream`).

## Wiring (GPS module ↔ ESP32)

| GPS module | ESP32 |
|------------|-------|
| TX         | RX0 (GPIO3) |
| RX         | TX0 (GPIO1) |
| VCC        | 3.3 V (or 5 V only if the module has an onboard regulator) |
| GND        | GND |

Default module baud: **9600** (NEO-6M/8M, ATGM336H). Change `GPS_BAUD` if yours differs.

## ⚠ UART0 = flash port

On most dev boards UART0 is also the USB-serial flash/monitor port:
- Debug prints go to **Serial1** (GPIO17 TX / GPIO16 RX) — never `Serial`.
- If **flashing hangs**, the GPS's TX is driving RX0: briefly disconnect GPS TX
  (or the GPS's VCC) while flashing, then reconnect.

## Test with the app

1. Flash the sketch (Board: `ESP32 Dev Module`, Arduino + `NimBLE-Arduino` lib).
2. NavBridge → Settings → **Bluetooth auto-connect** → scan → pick **NAV-OSM**.
3. On the phone:
   ```
   adb logcat -d | grep -E "\[MAP\]"
   ```
   → `[MAP] subscribed to GPS NMEA notify` means the app is receiving. Every
   `$…` line the ESP sends lands in `gpsNmeaStream` (not yet parsed into a
   position — that's the next step).

## Merge into the real firmware (`ble_nav.cpp` in ESP32_OSM_NAV)

The sketch is intentionally standalone so it's flashable/testable on its own.
To integrate into `ble_nav.cpp`:

1. **UART0 init** (in `setup()`; UART0 is free once you move debug off it):
   ```cpp
   // GPS on UART0 (TX0=GPIO1, RX0=GPIO3) @9600 8N1.
   Serial.begin(9600, SERIAL_8N1, 3, 1);
   ```
   (If `ble_nav.cpp` currently prints to `Serial`, move those to `Serial1` —
   e.g. `Serial1.begin(115200, SERIAL_8N1, 16, 17)` — or gate them.)

2. **NMEA forwarding** (in `loop()` / the char's existing notify path) — buffer
   chars from `Serial`, and on `'\n'` do:
   ```cpp
   // Trim '\r', then forward any complete '$' line to the app.
   if (len > 0 && buf[0] == '$' && navChar && navChar->getSubscribedCount() > 0) {
     navChar->setValue((uint8_t *)buf, len);
     navChar->notify();
   }
   ```
   where `navChar` is your existing `5a7e1001-…` characteristic (it already
   has NOTIFY — the app subscribes on connect).

3. That's it — the app side (`ble_map_clock.dart`) already routes any
   `$`-prefixed notify to `gpsNmeaStream`.

## Next step (app side, not done)

`gpsNmeaStream` currently just broadcasts raw lines. To use the ESP GPS as the
actual location source, the app needs a small NMEA parser (GGA/RMC → lat/lon/
speed/heading/accuracy) feeding a `Position`-like source that `_onGpsFix` can
consume — i.e. a "BLE GPS" source selectable in the same settings area. Say
the word and I'll build it.
