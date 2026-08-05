# NavBridge

BLE portable turn-by-turn navigation: routes + turn-by-turn directions
on your phone, mirrored in real time to an external BLE-connected monitor
(e-ink clock / HUD).

- OSM map + Nominatim search + OSRM routing (no API keys)
- Road type + speed limit lookup (Overpass)
- Google-Takeout-style trip logging (Records.json) with share/export
- Simulated drive mode for testing without GPS

## Getting Started

```sh
flutter pub get
flutter run
```

## Development

Quality gates run automatically via [pre-commit](https://pre-commit.com/)
(installed once) and on CI (GitHub Actions, `.github/workflows/ci.yml`):

```sh
# One-time setup
pip install pre-commit
pre-commit install

# What runs on every commit
#   - trailing whitespace / EOF / YAML checks
#   - `dart format` on staged .dart files
#   - `flutter analyze`
#   - `flutter test` (unit tests in test/)

# Run everything manually
tool/check.sh
```

The Flutter SDK is located automatically (`FLUTTER_ROOT`, `flutter` on PATH,
or `~/Documents/Eink/flutter_sdk`).
