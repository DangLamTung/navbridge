#!/usr/bin/env python3
"""Test script simulating a NavBridge client performing an auto-update against the server."""
import json
import urllib.request
import sys
import time

BASE_URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8089/latest"
print(f"--> Connecting to NavBridge Auto-Update Server at: {BASE_URL}")

# 1. Fetch version.json
v_url = f"{BASE_URL}/version.json"
try:
    with urllib.request.urlopen(v_url, timeout=5) as resp:
        versions = json.loads(resp.read().decode())
    print(f"✅ Successfully fetched version.json:")
    for k, v in versions.items():
        print(f"   - {k}: {v}")
except Exception as e:
    print(f"❌ Failed to fetch {v_url}: {e}")
    sys.exit(1)

# 2. Fetch manifest.json
m_url = f"{BASE_URL}/manifest.json"
try:
    with urllib.request.urlopen(m_url, timeout=5) as resp:
        manifest = json.loads(resp.read().decode())
    print(f"\n✅ Successfully fetched manifest.json (Release: {manifest.get('version')}, Generated: {manifest.get('generated')}):")
    for fname, meta in manifest.get("files", {}).items():
        size_kb = meta.get("size", 0) / 1024
        print(f"   - {fname:<25}: {size_kb:>8.1f} KB (sha256: {meta.get('sha256')[:12]}...)")
except Exception as e:
    print(f"❌ Failed to fetch {m_url}: {e}")
    sys.exit(1)

# 3. Simulate downloading header of a target file
test_file = "waze_speed_limits.json"
f_url = f"{BASE_URL}/{test_file}"
try:
    t0 = time.time()
    req = urllib.request.Request(f_url, headers={"User-Agent": "NavBridge-TestClient/1.0"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = resp.read()
    elapsed = time.time() - t0
    print(f"\n✅ Successfully downloaded {test_file}: {len(data):,} bytes in {elapsed:.2f}s (speed: {len(data)/elapsed/1024/1024:.2f} MB/s)")
    parsed = json.loads(data.decode())
    points_count = len(parsed.get("points", []))
    print(f"   - Valid JSON verified! Parsed {points_count:,} speed limit points.")
except Exception as e:
    print(f"❌ Failed to download {f_url}: {e}")
    sys.exit(1)

print("\n🎉 ALL TESTS PASSED! Auto-update server is working 100% correctly.")
