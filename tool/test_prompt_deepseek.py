#!/usr/bin/env python3
"""Test the NavBridge AI system prompt against DeepSeek directly (no app/phone
needed). Loads assets/ai/system_prompt.txt, injects the SAME live context +
REAL grounding block the app builds, streams a DeepSeek reply, and reports
whether the model emitted the [ĐI ĐẾN: ...] tool-call.

Usage (key from env or .env):
    DEEPSEEK_API_KEY=sk-... python3 tool/test_prompt_deepseek.py "tìm trạm xăng"
    # or add DEEPSEEK_API_KEY=... to .env and:  source tool/env.sh && python3 ...
"""
import json
import os
import re
import sys
import urllib.request

KEY = os.environ.get("DEEPSEEK_API_KEY", "")
ENDPOINT = "https://api.deepseek.com/chat/completions"
MODEL = "deepseek-chat"


def read_prompt():
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "..", "assets", "ai", "system_prompt.txt")
    with open(path, encoding="utf-8") as f:
        return f.read().strip()


def main():
    if not KEY:
        print("ERROR: set DEEPSEEK_API_KEY (export it or add to .env)")
        sys.exit(1)

    question = (
        sys.argv[1]
        if len(sys.argv) > 1
        else "tìm trạm xăng gần nhất, tôi muốn đi đến đó"
    )
    prompt = read_prompt()

    # Mirror what the app injects: live drive context + REAL POI grounding.
    context = (
        "\n\nNgữ cảnh hiện tại: Vị trí: 10.7769, 106.7009 (TP. HCM); "
        "Đường: Lê Lợi; Tốc độ: 35 km/h; Thời tiết: 31°C, nắng."
    )
    grounding = (
        "\n\nTrạm xăng gần đây (Google Maps thật — chỉ dùng danh sách này):\n"
        "- Petrolimex Lê Lợi (cách ~600 m)\n"
        "- PV Oil Nguyễn Huệ (cách ~1.2 km)\n"
        "- Shell Bến Nghé (cách ~1.8 km)"
    )
    user = question + context + grounding

    body = {
        "model": MODEL,
        "stream": True,
        "messages": [
            {"role": "system", "content": prompt},
            {"role": "user", "content": user},
        ],
    }
    req = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(body).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {KEY}",
        },
    )

    print(f"Q: {question}\n{'-' * 50}\n", flush=True)
    reply = []
    try:
        with urllib.request.urlopen(req, timeout=90) as res:
            for raw in res:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if not payload or payload == "[DONE]":
                    continue
                try:
                    j = json.loads(payload)
                except Exception:
                    continue
                for ch in j.get("choices", []):
                    delta = ch.get("delta", {}).get("content", "")
                    if delta:
                        print(delta, end="", flush=True)
                        reply.append(delta)
    except Exception as e:
        print(f"\nERROR calling DeepSeek: {e}")
        sys.exit(1)

    text = "".join(reply)
    print(f"\n{'-' * 50}")
    m = re.search(r"\[ĐI ĐẾN:\s*([^\]]+)\]", text)
    if m:
        print(f"✅ TOOL-CALL: [ĐI ĐẾN: {m.group(1).strip()}] -> app will navigate")
    else:
        print("⚠️  No [ĐI ĐẾN: ...] tool-call in the reply.")


if __name__ == "__main__":
    main()
