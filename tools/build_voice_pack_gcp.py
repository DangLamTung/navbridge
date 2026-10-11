#!/usr/bin/env python3
"""Build a NavBridge voice pack with Google Cloud Text-to-Speech.

Why build-time and not runtime: NavBridge is offline-first. The navigation voice
must work with no network, so the phrases are synthesized ONCE here and shipped
as `assets/audio/<pack>/*.mp3`, played by the native MediaPlayer through the
SAME queue as the TTS sentences (`lib/services/voice_guide.dart` →
`SoundAlerts.playCurrentSpeedLimit`). No SDK, no key and no network at ride time.

Two voice sources are supported:

  * **Cloned voice** — Chirp 3: Instant Custom Voice. You record ~10 s of
    reference audio plus the mandatory ~10 s consent sentence, POST them to
    `voices:generateVoiceCloningKey`, and get back a `voiceCloningKey` string
    (stored client-side; it is the voice). `create-key` below does this.
    ⚠ ACCESS IS ALLOW-LISTED — you must request it from Google Cloud sales
    first, otherwise the API answers PERMISSION_DENIED.
  * **A stock Chirp 3: HD voice** — e.g. `vi-VN-Chirp3-HD-Aoede`. No cloning,
    no allow-list, Vietnamese is supported. Use `--voice`.

Auth: Application Default Credentials, read from the gcloud CLI at run time
(`gcloud auth print-access-token`) so no key is ever written into the repo.
Sign in once with:

    gcloud auth application-default login
    gcloud config set project <YOUR_PROJECT>

Usage:

    # what voices/languages are available (needs auth)
    python3 tools/build_voice_pack_gcp.py voices --lang vi-VN

    # 1a. clone a voice (allow-listed feature)
    python3 tools/build_voice_pack_gcp.py create-key \
        --reference ~/voice/ref.wav --consent ~/voice/consent.wav \
        --out /tmp/nb_vckey.txt

    # 1b. or just pick a stock voice — no key needed

    # 2. see exactly what would be generated (NO credentials needed)
    python3 tools/build_voice_pack_gcp.py build --pack voice_vn_clone --dry-run

    # 3. synthesize the pack
    python3 tools/build_voice_pack_gcp.py build --pack voice_vn_clone \
        --key-file /tmp/nb_vckey.txt            # cloned voice
    #   … or: --voice vi-VN-Chirp3-HD-Aoede

    # 4. wire it up: add to `kVoicePacks` in lib/services/sound_alerts.dart
    #    VoicePackDef('voice_vn_clone', 'Giọng nhân bản — '),
    #    add 'assets/audio/voice_vn_clone/' to pubspec.yaml `assets:`,
    #    then `flutter pub get` and rebuild.

The pack ships the SAME 28 clip names the app already asks for, so a full pack
is a drop-in voice option. The speed clips are the only ones the app plays from
disk today; everything else (maneuvers, signs, cameras) is runtime TTS, so those
phrases stay TTS until a phrase→clip mapping layer exists.
"""
import argparse
import base64
import json
import os
import struct
import subprocess
import sys
import urllib.error
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = 'https://texttospeech.googleapis.com/v1beta1'

# The limits `SoundAlerts.supportedLimits` knows about — a pack must ship a clip
# for each or the caller falls back to TTS for that number.
LIMITS = [10, 20, 30, 35, 40, 50, 60, 70, 80, 90, 100, 110, 120]

# ⚠ The exact wording is what the driver hears; keep it in step with the TTS
# phrases in lib/ (nav_voice.dart) so the two never contradict each other.
# "km/h" is read naturally ("ki-lô-mét trên giờ") by the Vietnamese voices.
CLIP_TEXTS = {
    'current_speed_{n}': 'Tốc độ giới hạn hiện tại là {n} km/h',
    'next_speed_{n}': 'Tốc độ giới hạn tiếp theo là {n} km/h',
    'next_speed': 'Tốc độ giới hạn tiếp theo',
    'over_speed_limit': 'Bạn đang chạy quá tốc độ!',
}

# Road signs (Biển báo giao thông) - matches nav_signs.dart
ROAD_SIGN_TEXTS = {
    'sign_stop': 'Biển STOP sắp tới',
    'sign_nhuong_duong': 'Biển nhường đường sắp tới',
    'sign_vao_cam_vuot': 'Cấm vượt sắp tới',
    'sign_ra_cam_vuot': 'Hết cấm vượt sắp tới',
    'sign_cam_re_trai': 'Cấm rẽ trái sắp tới',
    'sign_cam_re_phai': 'Cấm rẽ phải sắp tới',
    'sign_cam_quay_dau': 'Cấm quay đầu sắp tới',
    'sign_cam_re_trai_quay_dau': 'Cấm rẽ trái và quay đầu sắp tới',
    'sign_cam_re_phai_quay_dau': 'Cấm rẽ phải và quay đầu sắp tới',
    'sign_chi_di_thang': 'Chỉ đi thẳng sắp tới',
    'sign_chi_re_phai': 'Chỉ rẽ phải sắp tới',
    'sign_chi_re_trai': 'Chỉ rẽ trái sắp tới',
    'sign_het_moi_lenh_cam': 'Hết mọi lệnh cấm sắp tới',
    'sign_giam_toc_do': 'Giảm tốc độ sắp tới',
    'sign_tram_thu_phi': 'Trạm thu phí sắp tới',
    'sign_giao_duong_sat': 'Đường ngang giao với đường sắt sắp tới',
    'sign_duong_ham': 'Hầm đường bộ sắp tới',
    'sign_cam_o_to': 'Cấm ô tô sắp tới',
    'sign_cam_xe_may': 'Cấm xe máy sắp tới',
    'sign_cam_do_xe': 'Cấm đỗ xe sắp tới',
    'sign_cam_di_thang': 'Cấm đi thẳng sắp tới',
    'sign_cam_re_hai_huong': 'Cấm rẽ trái và rẽ phải sắp tới',
    'sign_duong_mot_chieu': 'Đường một chiều sắp tới',
    'sign_lan_danh_rieng': 'Làn dành riêng sắp tới',
    'sign_den_giao_thong': 'Đèn giao thông sắp tới',
    'sign_vao_kdc': 'Bắt đầu khu dân cư',
    'sign_ra_kdc': 'Hết khu dân cư',
    'sign_vao_kdc_ahead': 'Bắt đầu khu dân cư phía trước',
    'sign_ra_kdc_ahead': 'Hết khu dân cư phía trước',
}

# Camera alerts (Cảnh báo camera) - matches nav_weather.dart
CAMERA_TEXTS = {
    'cam_toc_do': 'Camera tốc độ phía trước',
    'cam_toc_do_ngay': 'Camera tốc độ ngay phía trước',
    'cam_giao_thong': 'Camera giám sát giao thông phía trước',
    'cam_giao_thong_ngay': 'Camera giám sát giao thông ngay phía trước',
    'cam_phat_nguoi': 'Camera phạt nguội phía trước',
    'cam_phat_nguoi_ngay': 'Camera phạt nguội ngay phía trước',
    'cam_den_do': 'Camera đèn đỏ phía trước',
    'cam_den_do_ngay': 'Camera đèn đỏ ngay phía trước',
    'cam_kiem_tra_toc_do': 'Kiểm tra tốc độ',
}

# Navigation & system alerts (Hành trình, cảnh báo & hệ thống)
ALERT_MANEUVER_TEXTS = {
    'reroute': 'Đang tính lại đường',
    'gps_lost': 'Mất tín hiệu GPS',
    'gps_found': 'Đã có tín hiệu GPS',
    'arrived': 'Bạn đã đến nơi',
    'arrived_left': 'Điểm đến bên trái',
    'arrived_right': 'Điểm đến bên phải',
    'warning_overspeed': 'Giảm tốc độ! Vượt quá tốc độ.',
    'warning_motorway': 'Chú ý! Xe mô tô không được phép đi vào đường cao tốc.',
    'tram_dung': 'Trạm dừng chân',
    'tram_dung_cao_toc': 'Trạm dừng cao tốc',
    'turn_left': 'Rẽ trái',
    'turn_right': 'Rẽ phải',
    'turn_slight_left': 'Rẽ trái nhẹ',
    'turn_slight_right': 'Rẽ phải nhẹ',
    'turn_straight': 'Đi thẳng',
    'turn_uturn': 'Quay đầu',
}

# The consent sentence is FIXED per language — Google rejects a custom script.
CONSENT_SCRIPT = {
    'vi-VN': 'Tôi là chủ sở hữu giọng nói này và tôi đồng ý cho Google sử dụng '
             'giọng nói này để tạo mô hình giọng nói tổng hợp.',
    'en-US': 'I am the owner of this voice and I consent to Google using this '
             'voice to create a synthetic voice model.',
}

# Default A/B phrases for `sample`: the line the driver hears most (the current
# limit) and the one that must cut through (the overspeed warning).
DEFAULT_SAMPLE_PHRASES = [
    'Tốc độ giới hạn hiện tại là 50 km/h',
    'Vượt quá tốc độ. Giảm tốc độ!',
]

# ---- MPEG frame walker: exact mp3 duration, no dependencies -----------------
# (copied from tools/build_voice_pack_vn.py — the pack MANIFEST records it)
BITRATE_V1_L3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
BITRATE_V2_L3 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0]
SAMPLE_RATE = {3: [44100, 48000, 32000], 2: [22050, 24000, 16000], 0: [11025, 12000, 8000]}


def mp3_seconds(path: str) -> float:
    data = open(path, 'rb').read()
    i = 0
    if data[:3] == b'ID3' and len(data) > 10:
        i = 10 + ((data[6] & 0x7F) << 21 | (data[7] & 0x7F) << 14 |
                  (data[8] & 0x7F) << 7 | (data[9] & 0x7F))
    total = 0.0
    n = len(data)
    while i + 4 <= n:
        if data[i] != 0xFF or (data[i + 1] & 0xE0) != 0xE0:
            i += 1
            continue
        h = struct.unpack('>I', data[i:i + 4])[0]
        ver = (h >> 19) & 0x3
        layer = (h >> 17) & 0x3
        brx = (h >> 12) & 0xF
        srx = (h >> 10) & 0x3
        pad = (h >> 9) & 0x1
        if ver == 1 or layer != 1 or brx in (0, 15) or srx == 3:
            i += 1
            continue
        is_v1 = (ver == 3)
        br = (BITRATE_V1_L3 if is_v1 else BITRATE_V2_L3)[brx] * 1000
        sr = SAMPLE_RATE[ver][srx]
        if br == 0:
            i += 1
            continue
        flen = (144 if is_v1 else 72) * br // sr + pad
        if flen <= 4:
            i += 4
            continue
        total += (1152 if is_v1 else 576) / sr
        i += flen
    return total


# ---- auth ------------------------------------------------------------------

def access_token() -> str:
    """ADC via the gcloud CLI — the token is fetched per run, never stored."""
    tok = os.environ.get('GOOGLE_ACCESS_TOKEN')
    if tok:
        return tok.strip()
    try:
        out = subprocess.run(
            ['gcloud', 'auth', 'print-access-token'],
            capture_output=True, text=True, check=True,
        )
        return out.stdout.strip()
    except FileNotFoundError:
        sys.exit('gcloud not found — install the Google Cloud CLI, or set '
                 'GOOGLE_ACCESS_TOKEN (e.g. from a service account) instead.')
    except subprocess.CalledProcessError as e:
        sys.exit('gcloud auth print-access-token failed: %s\n'
                 'Run: gcloud auth application-default login' % e.stderr.strip())


def project_id() -> str:
    for key in ('GOOGLE_CLOUD_PROJECT', 'GCLOUD_PROJECT', 'CLOUDSDK_CORE_PROJECT'):
        if os.environ.get(key):
            return os.environ[key]
    try:
        return subprocess.run(['gcloud', 'config', 'get-value', 'project'],
                              capture_output=True, text=True, check=True
                              ).stdout.strip()
    except Exception:
        return ''


def http_error(e: urllib.error.HTTPError, url: str) -> str:
    """The API error verbatim, plus the fix when it is the classic 403."""
    detail = e.read().decode('utf-8', 'replace')
    msg = 'HTTP %d from %s\n%s' % (e.code, url, detail)
    low = detail.lower()
    if e.code == 403 and ('quota project' in low or 'service_disabled' in low
                          or 'has not been used' in low or 'disabled' in low):
        msg += ('\n\nFix (one-time, per project):\n'
                '  gcloud services enable texttospeech.googleapis.com\n'
                '  gcloud auth application-default set-quota-project %s\n'
                % (project_id() or '<PROJECT_ID>'))
    if e.code == 403 and 'allow' in low:
        msg += ('\n\nNOTE: Chirp 3 Instant Custom Voice (voice cloning) is an '
                'ALLOW-LISTED feature — request access from Google Cloud sales. '
                'A stock Chirp 3: HD voice needs no allow-list: use --voice.')
    return msg


# ---- Gemini TTS (voice design / replication live here) ---------------------
#
# `gemini-3.8-flash-tts` on Vertex AI. Verified working on the talon project
# 2026-10-08: generateContent with responseModalities ["AUDIO"] returns
# `audio/wav`, 24 kHz mono. NOTE the limits, they are not bugs:
#   * it is a PREVIEW model, location `global`;
#   * MP3/OGG output is NOT supported — only WAV (unary) or raw PCM (streaming),
#     and the sample rate cannot be set. The pack needs mp3, so the WAV is
#     converted locally with ffmpeg/lame.
#   * `speechConfig` also accepts an Extended Voice Library id, a designed voice
#     (`voice_...`), or a replicated voice (`voice_...` / stateless
#     `voicekey_...`) — those last two ARE the voice-clone path.
GEMINI_MODEL = 'gemini-3.8-flash-tts'
GEMINI_LOCATION = 'global'


def gemini_wav(text: str, voice: str, token: str, style: str = "") -> bytes:
    """Synthesize [text] with Gemini TTS → WAV bytes."""
    proj = project_id()
    if not proj:
        sys.exit('no project — run: gcloud config set project <PROJECT_ID>')
    url = ('https://aiplatform.googleapis.com/v1/projects/%s/locations/%s/'
           'publishers/google/models/%s:generateContent'
           % (proj, GEMINI_LOCATION, GEMINI_MODEL))
    v_conf = {'voice': voice} if voice.startswith('voice_') else {'prebuiltVoiceConfig': {'voiceName': voice}}
    part = {'text': text}
    if style:
        part['speech_metadata'] = {'style': style}
    body = {
        'contents': [{'role': 'user', 'parts': [part]}],
        'generationConfig': {
            'responseModalities': ['AUDIO'],
            'speechConfig': {
                'voiceConfig': v_conf,
            },
        },
    }
    res = post(url, body, token)
    parts = ((res.get('candidates') or [{}])[0].get('content') or {}).get('parts') or []
    for p in parts:
        inline = p.get('inlineData') or {}
        if inline.get('data'):
            return base64.b64decode(inline['data'])
    raise RuntimeError('no audio in the Gemini response: %s' % json.dumps(res)[:300])


def wav_to_mp3(wav: bytes, dst_mp3: str) -> bool:
    """Gemini TTS only emits WAV; the app's packs are .mp3. Returns True on ok."""
    tmp = dst_mp3 + '.tmp.wav'
    with open(tmp, 'wb') as f:
        f.write(wav)
    for cmd in (['ffmpeg', '-y', '-loglevel', 'error', '-i', tmp,
                 '-codec:a', 'libmp3lame', '-b:a', '64k', dst_mp3],
                ['lame', '-b', '64', '--quiet', tmp, dst_mp3]):
        try:
            if subprocess.run(cmd, capture_output=True).returncode == 0:
                os.remove(tmp)
                return True
        except FileNotFoundError:
            continue
    print('   WARNING: neither ffmpeg nor lame found — keeping .wav', file=sys.stderr)
    os.replace(tmp, dst_mp3.rsplit('.', 1)[0] + '.wav')
    return False


def cmd_gemini_voices(args):
    """The Extended Voice Library + prebuilt voices available for Gemini TTS."""
    token = access_token()
    proj = project_id()
    if not proj:
        sys.exit('no project — run: gcloud config set project <PROJECT_ID>')
    url = ('https://aiplatform.googleapis.com/v1/projects/%s/locations/%s/'
           'voices?pageSize=200' % (proj, GEMINI_LOCATION))
    req = urllib.request.Request(url, headers=auth_headers(token))
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            data = json.loads(r.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        raise SystemExit(http_error(e, '%s/voices' % GEMINI_LOCATION))
    voices = data.get('voices', [])
    print('%d voices (first 40)' % len(voices))
    for v in voices[:40]:
        print('  %-46s %-10s %s' % (v.get('id', ''), v.get('languageCode', ''),
                                    (v.get('description') or '')[:60]))


def auth_headers(token: str) -> dict:
    """Authorization + the QUOTA PROJECT, which user credentials need.

    ⭐ Without `x-goog-user-project` every call fails 403 "requires a quota
    project" — the token comes from the gcloud CLI account, whose default
    quota project is nothing you own. Verified 2026-10-08: the same request
    succeeds with this header and 403s without it.
    """
    headers = {
        'Authorization': 'Bearer %s' % token,
        'Content-Type': 'application/json; charset=utf-8',
    }
    proj = project_id()
    if proj:
        headers['x-goog-user-project'] = proj
    return headers


def post(url: str, body: dict, token: str) -> dict:
    req = urllib.request.Request(
        url, data=json.dumps(body).encode('utf-8'),
        headers=auth_headers(token), method='POST')
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        if e.code == 401:
            tok = access_token()
            req = urllib.request.Request(
                url, data=json.dumps(body).encode('utf-8'),
                headers=auth_headers(tok), method='POST')
            try:
                with urllib.request.urlopen(req, timeout=120) as r:
                    return json.loads(r.read().decode('utf-8'))
            except urllib.error.HTTPError as e2:
                raise RuntimeError(http_error(e2, url))
        raise RuntimeError(http_error(e, url))


# ---- the clip list ---------------------------------------------------------

def clip_specs(only=None, speed_only=False):
    """[(filename_without_ext, text)] in pack order."""
    out = []
    for lim in LIMITS:
        for tmpl in ('current_speed_{n}', 'next_speed_{n}'):
            out.append((tmpl.format(n=lim), CLIP_TEXTS[tmpl].format(n=lim)))
    out.append(('next_speed', CLIP_TEXTS['next_speed']))
    out.append(('over_speed_limit', CLIP_TEXTS['over_speed_limit']))
    if not speed_only:
        for k, v in ROAD_SIGN_TEXTS.items():
            out.append((k, v))
        for k, v in CAMERA_TEXTS.items():
            out.append((k, v))
        for k, v in ALERT_MANEUVER_TEXTS.items():
            out.append((k, v))
    if only:
        want = {s.strip() for s in only.split(',') if s.strip()}
        out = [c for c in out if c[0] in want]
    return out


def voice_payload(args):
    """`voice` object for text:synthesize — cloned key or a stock voice name."""
    if args.key_file:
        key = open(os.path.expanduser(args.key_file), encoding='utf-8').read().strip()
        if not key:
            sys.exit('voice cloning key file is empty: %s' % args.key_file)
        return {'language_code': args.lang,
                'voice_clone': {'voice_cloning_key': key}}
    if not args.voice:
        sys.exit('give either --key-file (cloned voice) or --voice '
                 '(e.g. vi-VN-Chirp3-HD-Aoede); --dry-run needs neither')
    return {'language_code': args.lang, 'name': args.voice}


# ---- subcommands -----------------------------------------------------------

def cmd_voices(args):
    token = access_token()
    req = urllib.request.Request(
        '%s/voices?languageCode=%s' % (API, args.lang),
        headers=auth_headers(token))
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            data = json.loads(r.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        raise SystemExit(http_error(e, '%s/voices' % API))
    voices = data.get('voices', [])
    print('%d voices for %s' % (len(voices), args.lang))
    for v in voices:
        print('  %-34s %-8s %s' % (
            v.get('name', ''), v.get('ssmlGender', ''),
            v.get('naturalSampleRateHertz', '')))
    return 0


def cmd_create_key(args):
    token = access_token()
    script = args.consent_script or CONSENT_SCRIPT.get(args.lang)
    if not script:
        sys.exit('no consent script known for %s — pass --consent-script' % args.lang)
    body = {
        'reference_audio': {
            'audio_config': {'audio_encoding': args.encoding},
            'content': base64.b64encode(open(os.path.expanduser(args.reference), 'rb').read()).decode(),
        },
        'voice_talent_consent': {
            'audio_config': {'audio_encoding': args.encoding},
            'content': base64.b64encode(open(os.path.expanduser(args.consent), 'rb').read()).decode(),
        },
        'consent_script': script,
        'language_code': args.lang,
    }
    print('creating voice cloning key (%s, consent script in %s)…' % (args.lang, args.lang))
    res = post('%s/voices:generateVoiceCloningKey' % API, body, token)
    key = res.get('voiceCloningKey')
    if not key:
        raise SystemExit('no voiceCloningKey in the response: %s' % json.dumps(res)[:400])
    out = os.path.expanduser(args.out)
    with open(out, 'w', encoding='utf-8') as f:
        f.write(key)
    os.chmod(out, 0o600)
    print('voice cloning key written to %s (%d chars, chmod 600)'
          % (out, len(key)))
    print('NOTE: the key IS the voice. Keep it out of the repo — .gitignore it, '
          'or keep it under /tmp for a one-off build.')
    return 0


def cmd_build(args):
    speed_only = getattr(args, 'speed_only', False)
    clips = clip_specs(args.only, speed_only=speed_only)
    out_dir = os.path.join(REPO, 'assets', 'audio', args.pack)

    if args.dry_run:
        print('pack: %s  (%d clips, %s, rate %s)'
              % (args.pack, len(clips), args.voice or 'CLONED VOICE', args.rate))
        print('out:  %s' % os.path.relpath(out_dir, REPO))
        total_chars = 0
        for name, text in clips:
            total_chars += len(text)
            print('  %-20s %s' % (name + '.mp3', text))
        print('\ntotal characters: %d' % total_chars)
        print('(no credentials used; pass --key-file/--voice without --dry-run '
              'to synthesize)')
        return 0

    token = access_token()
    voice = voice_payload(args)
    gemini = getattr(args, 'engine', 'chirp') == 'gemini'
    if gemini:
        if not args.voice:
            sys.exit('--engine gemini needs --voice (a prebuilt name like Kore, '
                     'or a voice id from `gemini-voices`)')
        print('engine: %s (%s, %s) — WAV out, converting to mp3'
              % (GEMINI_MODEL, GEMINI_LOCATION, args.voice))
    os.makedirs(out_dir, exist_ok=True)
    manifest_path = os.path.join(out_dir, 'MANIFEST.json')
    manifest = {}
    if os.path.exists(manifest_path) and not args.force:
        try:
            manifest = json.load(open(manifest_path, encoding='utf-8')).get('clips', {})
        except Exception:
            manifest = {}

    failed = []
    for i, (name, text) in enumerate(clips, 1):
        dst = os.path.join(out_dir, name + '.mp3')
        if os.path.exists(dst) and not args.force:
            print('[%d/%d] %s — exists, skipped (--force to redo)'
                  % (i, len(clips), name))
            continue
        body = {
            'input': {'text': text},
            'voice': voice,
            'audio_config': {'audio_encoding': 'MP3', 'speaking_rate': args.rate},
        }
        print('[%d/%d] %s ← %s' % (i, len(clips), name, text))
        try:
            if gemini:
                style = getattr(args, 'style', '')
                if not style:
                    if 'over_speed' in name or 'warning' in name:
                        style = 'urgent warning, alert, sharp, authoritative and clear'
                    elif 'sign_' in name or 'cam_' in name:
                        style = 'attentive, alert, crystal-clear, refined and elegant navigation alert'
                    elif 'turn_' in name or 'arrived' in name or 'reroute' in name or 'gps' in name:
                        style = 'gentle, crystal-clear, articulate, elegant navigation guidance'
                    else:
                        style = 'calm, elegant, articulate, crystal-clear, refined and melodious'
                audio = gemini_wav(text, args.voice, token, style=style)
                if not wav_to_mp3(audio, dst):
                    # No encoder: the clip landed as .wav — remember that.
                    dst = dst.rsplit('.', 1)[0] + '.wav'
            else:
                res = post('%s/text:synthesize' % API, body, token)
                audio = base64.b64decode(res.get('audioContent', ''))
        except SystemExit as e:
            failed.append((name, str(e)))
            print('   FAILED: %s' % e, file=sys.stderr)
            continue
        if audio is None or len(audio) < 512:
            failed.append((name, 'empty audio'))
            continue
        if not gemini:
            with open(dst, 'wb') as f:
                f.write(audio)
        manifest[os.path.basename(dst)] = {
            'text': text,
            'size': os.path.getsize(dst),
            'seconds': round(mp3_seconds(dst), 3),
            'source': ('gemini-tts:%s' % args.voice) if gemini
                      else 'gcp-tts:%s' % (args.voice or 'voice-clone'),
            'lang': args.lang,
            'rate': args.rate,
        }
        if args.sleep:
            import time
            time.sleep(args.sleep)

    doc = {
        'pack': args.pack,
        'lang': args.lang,
        'engine': 'Google Cloud Text-to-Speech (v1beta1 text:synthesize)',
        'voice': args.voice or 'Chirp 3 Instant Custom Voice (cloned)',
        'speaking_rate': args.rate,
        'generator': 'tools/build_voice_pack_gcp.py',
        'clips': manifest,
    }
    with open(manifest_path, 'w', encoding='utf-8') as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
    total = sum(v.get('seconds', 0) for v in manifest.values())
    print('\n%d clips, %.1f s of speech, %.2f MB → %s'
          % (len(manifest), total,
             sum(v.get('size', 0) for v in manifest.values()) / 1e6,
             os.path.relpath(out_dir, REPO)))
    if failed:
        print('FAILED clips: %s' % ', '.join(n for n, _ in failed), file=sys.stderr)
        print('re-run with --only %s' % ','.join(n for n, _ in failed), file=sys.stderr)
        return 1
    print('\nNow wire it up:\n'
          "  * pubspec.yaml  assets:  add 'assets/audio/%s/'\n"
          "  * lib/services/sound_alerts.dart  kVoicePacks: add\n"
          "      VoicePackDef('%s', 'Giọng nhân bản (Google)')\n"
          '  * flutter pub get && rebuild' % (args.pack, args.pack))
    return 0


def cmd_sample(args):
    """One phrase per voice — the A/B set for picking a voice in the browser."""
    token = access_token()
    out_dir = args.out if os.path.isabs(args.out) else os.path.join(REPO, args.out)
    os.makedirs(out_dir, exist_ok=True)
    voices = [v.strip() for v in args.voices.split(',') if v.strip()]
    phrases = [p.strip() for p in args.phrases.split(',') if p.strip()]
    rows = []
    for vi, voice in enumerate(voices, 1):
        for pi, text in enumerate(phrases, 1):
            name = '%s__p%d' % (voice.replace('/', '_'), pi)
            dst = os.path.join(out_dir, name + '.mp3')
            body = {
                'input': {'text': text},
                'voice': {'language_code': args.lang, 'name': voice},
                'audio_config': {'audio_encoding': 'MP3', 'speaking_rate': args.rate},
            }
            print('[%d/%d] %s ← %s' % (vi, len(voices), voice, text))
            res = post('%s/text:synthesize' % API, body, token)
            audio = base64.b64decode(res.get('audioContent', ''))
            with open(dst, 'wb') as f:
                f.write(audio)
            rows.append({'file': name + '.mp3', 'voice': voice, 'text': text,
                         'seconds': round(mp3_seconds(dst), 3),
                         'size': len(audio)})
            if args.sleep:
                import time
                time.sleep(args.sleep)
    with open(os.path.join(out_dir, 'MANIFEST.json'), 'w', encoding='utf-8') as f:
        json.dump({'engine': 'gcp-tts', 'rate': args.rate, 'lang': args.lang,
                   'samples': rows}, f, ensure_ascii=False, indent=1)
    print('\n%d samples in %s' % (len(rows), os.path.relpath(out_dir, REPO)))
    print('next:  python3 tools/build_voice_pack_gcp.py web --dir %s '
          '--out docs/voice_audition.html --title "NavBridge voice audition"'
          % os.path.relpath(out_dir, REPO))
    return 0


def _hms(seconds):
    if not seconds:
        return '-'
    return '%.2fs' % seconds


def cmd_web(args):
    """A static page that plays every clip in a folder — open it in a browser."""
    src = args.dir if os.path.isabs(args.dir) else os.path.join(REPO, args.dir)
    if not os.path.isdir(src):
        sys.exit('not a folder: %s' % src)
    files = sorted(f for f in os.listdir(src) if f.lower().endswith('.mp3'))
    if not files:
        sys.exit('no .mp3 files in %s' % src)
    rel = os.path.relpath(src, os.path.dirname(os.path.abspath(
        args.out if os.path.isabs(args.out) else os.path.join(REPO, args.out))))
    title = args.title or ('NavBridge voice pack — %s' % os.path.basename(src))
    rows = []
    for f in files:
        secs = mp3_seconds(os.path.join(src, f))
        rows.append((f, secs))
    total = sum(s for _, s in rows)
    parts = [
        '<!doctype html><html lang="vi"><head><meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width,initial-scale=1">',
        '<title>%s</title>' % title,
        '<style>',
        'body{font:15px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;'
        'margin:0;padding:24px;background:#0f1115;color:#e8eaed}',
        'h1{font-size:19px;margin:0 0 4px}',
        '.sub{color:#9aa0a6;font-size:13px;margin-bottom:18px}',
        'table{border-collapse:collapse;width:100%;max-width:1040px}',
        'th,td{text-align:left;padding:7px 10px;border-bottom:1px solid #23262b;'
        'vertical-align:middle}',
        'th{color:#9aa0a6;font-weight:600;font-size:12px;text-transform:uppercase;'
        'letter-spacing:.04em}',
        'td.n{font-variant-numeric:tabular-nums;color:#9aa0a6;white-space:nowrap}',
        'code{background:#1b1e24;padding:1px 5px;border-radius:4px;font-size:13px}',
        'audio{height:30px}',
        '</style></head><body>',
        '<h1>%s</h1>' % title,
        '<div class="sub">%d clips · %.1f s of speech · folder <code>%s</code>'
        '</div>' % (len(rows), total, rel),
        '<table><thead><tr><th>#</th><th>clip</th><th>length</th>'
        '<th>listen</th></tr></thead><tbody>',
    ]
    for i, (f, secs) in enumerate(rows, 1):
        parts.append(
            '<tr><td class="n">%d</td><td><code>%s</code></td>'
            '<td class="n">%s</td><td><audio controls preload="none" '
            'src="%s/%s"></audio></td></tr>'
            % (i, f, _hms(secs), rel.replace(os.sep, '/'), f))
    parts += ['</tbody></table>',
              '<div class="sub" style="margin-top:18px">Regenerate the pack with '
              'another voice:<br><code>python3 tools/build_voice_pack_gcp.py '
              'build --pack %s --voice vi-VN-Chirp3-HD-&lt;Name&gt; --force'
              '</code></div>' % os.path.basename(src),
              '</body></html>']
    out = args.out if os.path.isabs(args.out) else os.path.join(REPO, args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(parts))
    print('wrote %s (%d clips, %.1f s)' % (os.path.relpath(out, REPO), len(rows), total))
    return 0


def _b64_clip(path):
    return base64.b64encode(open(path, 'rb').read()).decode('ascii')


SITE_CSS = """
*{box-sizing:border-box}
body{font:15px/1.55 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
 margin:0;padding:0;background:#0b0d11;color:#e8eaed}
.wrap{max-width:1060px;margin:0 auto;padding:28px 22px 60px}
h1{font-size:22px;margin:0 0 6px;letter-spacing:-.2px}
h2{font-size:16px;margin:34px 0 6px;padding-top:16px;border-top:1px solid #22262c}
h2 .n{color:#6b7280;font-weight:400}
.sub{color:#9aa0a6;font-size:13px;margin:0 0 14px}
.card{background:#14171c;border:1px solid #22262c;border-radius:12px;
 padding:14px 16px;margin:10px 0}
.row{display:grid;grid-template-columns:1fr auto auto;gap:12px;align-items:center;
 padding:9px 0;border-bottom:1px solid #1d2126}
.row:last-child{border-bottom:0}
.row.now{background:#1b2027;border-radius:8px}
.name{font-variant-numeric:tabular-nums}
.tag{font-size:12px;color:#9aa0a6}
code{background:#1b1e24;padding:1px 6px;border-radius:5px;font-size:13px}
audio{height:32px}
.btn{background:#2b3138;border:1px solid #39414a;color:#e8eaed;border-radius:8px;
 padding:7px 13px;font:inherit;font-size:13px;cursor:pointer}
.btn:hover{background:#333b44}
.bar{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:12px 0 0}
.pill{background:#12281c;border:1px solid #1f5136;color:#7ee2a8;border-radius:99px;
 padding:3px 10px;font-size:12px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(310px,1fr));gap:12px}
.vname{font-weight:600;font-size:14px;margin-bottom:6px}
.vname .g{color:#9aa0a6;font-weight:400;font-size:12px}
footer{color:#6b7280;font-size:12px;margin-top:34px}
"""


def cmd_site(args):
    """ONE self-contained page: every clip inlined as a data URI.

    Deliberately single-file: it opens by double-click (no server, no relative
    paths to break), can be AirDropped to the phone, and still works when the
    assets folder has moved.
    """
    pack_dir = args.pack_dir if os.path.isabs(args.pack_dir) else os.path.join(REPO, args.pack_dir)
    if not os.path.isdir(pack_dir):
        sys.exit('not a folder: %s' % pack_dir)
    manifest = {}
    mp = os.path.join(pack_dir, 'MANIFEST.json')
    if os.path.exists(mp):
        manifest = json.load(open(mp, encoding='utf-8'))

    def clip_row(path, label, text=None, group=None):
        secs = mp3_seconds(path)
        return {
            'label': label, 'text': text or '', 'group': group,
            'secs': secs, 'uri': 'data:audio/mpeg;base64,' + _b64_clip(path),
        }

    # ---- section 1: the pack, in its natural order -------------------------
    files = sorted(f for f in os.listdir(pack_dir) if f.lower().endswith('.mp3'))
    if not files:
        sys.exit('no mp3 in %s' % pack_dir)
    pack_rows = []
    for f in files:
        entry = (manifest.get('clips') or {}).get(f) or {}
        pack_rows.append(clip_row(os.path.join(pack_dir, f), f[:-4], entry.get('text')))
    pack_secs = sum(r['secs'] for r in pack_rows)

    # ---- section 2: the multi-voice A/B set (optional) ---------------------
    voices = {}
    if args.audition_dir:
        ad = args.audition_dir if os.path.isabs(args.audition_dir) else os.path.join(REPO, args.audition_dir)
        if os.path.isdir(ad):
            am = {}
            amp = os.path.join(ad, 'MANIFEST.json')
            if os.path.exists(amp):
                for s in json.load(open(amp, encoding='utf-8')).get('samples', []):
                    am[s['file']] = s
            for f in sorted(os.listdir(ad)):
                if not f.lower().endswith('.mp3'):
                    continue
                meta = am.get(f, {})
                voice = meta.get('voice') or f.split('__')[0]
                voices.setdefault(voice, []).append(
                    clip_row(os.path.join(ad, f), f, meta.get('text')))

    h = ['<!doctype html><html lang="vi"><head><meta charset="utf-8">',
         '<meta name="viewport" content="width=device-width,initial-scale=1">',
         '<title>%s</title><style>%s</style></head><body><div class="wrap">'
         % (args.title, SITE_CSS),
         '<h1>%s</h1>' % args.title,
         '<p class="sub">Google Cloud Text-to-Speech · Chirp 3: HD · vi-VN · '
         'giọng đọc sẵn cho NavBridge</p>',
         '<div class="bar">',
         '<span class="pill">%s</span>' % (manifest.get('voice') or 'pack'),
         '<span class="pill">%d clip</span>' % len(pack_rows),
         '<span class="pill">%.1f s</span>' % pack_secs,
         '<span class="pill">rate %s</span>' % (manifest.get('speaking_rate', args.rate)),
         '<button class="btn" onclick="stopAll()">⏹ Dừng</button>',
         '</div>']

    if voices:
        h.append('<h2>So sánh giọng đọc <span class="n">— cùng 2 câu, chọn giọng '
                 'bạn muốn</span></h2>')
        h.append('<p class="sub">Nghe câu "Tốc độ giới hạn hiện tại là 50 km/h" và '
                 'câu cảnh báo. Khi đã chọn, chạy lại lệnh build với '
                 '<code>--voice &lt;tên&gt;</code>.</p>')
        h.append('<div class="grid">')
        for voice, rows in sorted(voices.items()):
            short = voice.split('-')[-1]
            gender = ''
            h.append('<div class="card"><div class="vname">%s <span class="g">%s</span>'
                     '</div>' % (short, voice))
            for r in rows:
                h.append('<div class="row"><div><div class="name">%s</div>'
                         '<div class="tag">%s</div></div>'
                         '<div class="tag">%.2fs</div>'
                         '<audio controls preload="none" src="%s"></audio></div>'
                         % (r['text'] or r['label'], r['label'], r['secs'], r['uri']))
            h.append('</div>')
        h.append('</div>')

    h.append('<h2>Pack đầy đủ <span class="n">— %d clip đã lưu</span></h2>' % len(pack_rows))
    h.append('<p class="sub">Tất cả thông báo giọng nói cho NavBridge: tốc độ, biển báo, '
             'camera giao thông và chỉ dẫn hành trình.</p>')
    h.append('<div class="card">')
    groups = [
        ('current_speed', 'Giới hạn tốc độ hiện tại'),
        ('next_speed', 'Giới hạn tốc độ tiếp theo'),
        ('over_speed', 'Cảnh báo quá tốc độ'),
        ('sign_', 'Biển báo giao thông'),
        ('cam_', 'Cảnh báo Camera giao thông'),
        (('reroute', 'gps', 'arrived', 'warning', 'tram'), 'Cảnh báo hành trình & Hệ thống'),
        ('turn_', 'Chỉ dẫn điều hướng'),
    ]
    for key, gname in groups:
        if isinstance(key, tuple):
            rows = [r for r in pack_rows if any(r['label'].startswith(k) for k in key)]
        else:
            rows = [r for r in pack_rows if r['label'].startswith(key)]
        if not rows:
            continue
        h.append('<div class="tag" style="margin:12px 0 4px;font-weight:600;color:#8ab4f8">%s</div>' % gname)
        for r in rows:
            h.append('<div class="row"><div><div class="name">%s</div>'
                     '<div class="tag">%s</div></div>'
                     '<div class="tag">%.2fs</div>'
                     '<audio controls preload="none" src="%s"></audio></div>'
                     % (r['text'] or r['label'], r['label'], r['secs'], r['uri']))
    h.append('</div>')

    h.append('<footer>Generated by <code>tools/build_voice_pack_gcp.py site</code>. '
             'All clips are embedded — no server needed.</footer>')
    h.append('<script>function stopAll(){document.querySelectorAll("audio")'
             '.forEach(a=>{a.pause();a.currentTime=0;});}'
             'document.addEventListener("play",e=>{document.querySelectorAll'
             '("audio").forEach(a=>{if(a!==e.target)a.pause();});},true);</script>')
    h.append('</div></body></html>')

    out = args.out if os.path.isabs(args.out) else os.path.join(REPO, args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(h))
    print('wrote %s  (%d pack clips + %d voices, %.1f MB)'
          % (os.path.relpath(out, REPO), len(pack_rows), len(voices),
             os.path.getsize(out) / 1e6))
    return 0


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)

    v = sub.add_parser('voices', help='list the voices/languages available')
    v.add_argument('--lang', default='vi-VN')
    v.set_defaults(func=cmd_voices)

    k = sub.add_parser('create-key', help='create a Chirp 3 Instant Custom Voice '
                                         'cloning key (allow-listed feature)')
    k.add_argument('--reference', required=True,
                   help='~10 s of reference audio (LINEAR16/PCM/MP3/M4A)')
    k.add_argument('--consent', required=True,
                   help='~10 s of the FIXED consent sentence, same environment')
    k.add_argument('--encoding', default='LINEAR16',
                   choices=['LINEAR16', 'PCM', 'MP3', 'M4A'])
    k.add_argument('--lang', default='vi-VN')
    k.add_argument('--consent-script', default=None,
                   help='override the fixed consent sentence (not recommended)')
    k.add_argument('--out', default='/tmp/nb_voice_cloning_key.txt')
    k.set_defaults(func=cmd_create_key)

    b = sub.add_parser('build', help='synthesize the pack')
    b.add_argument('--pack', required=True,
                   help='folder name under assets/audio/ (e.g. voice_vn_gcp)')
    b.add_argument('--engine', default='chirp', choices=['chirp', 'gemini'],
                   help='chirp = Cloud TTS (mp3 out); gemini = Gemini 3.8 Flash '
                        'TTS (wav out, converted to mp3)')
    b.add_argument('--lang', default='vi-VN')
    b.add_argument('--rate', type=float, default=1.0, help='speaking rate 0.25–2.0')
    b.add_argument('--voice', default=None,
                   help='stock voice name, e.g. vi-VN-Chirp3-HD-Aoede')
    b.add_argument('--key-file', default=None,
                   help='voice cloning key file created by `create-key`')
    b.add_argument('--only', default=None,
                   help='comma-separated clip names to (re)generate')
    b.add_argument('--force', action='store_true', help='overwrite existing clips')
    b.add_argument('--dry-run', action='store_true',
                   help='print the clip list; no credentials, no network')
    b.add_argument('--speed-only', action='store_true',
                   help='only generate the 28 speed limit clips (skip signs/cameras)')
    b.add_argument('--style', default='',
                   help='style delivery prompt for Gemini TTS (e.g. "calm, elegant, articulate")')
    b.add_argument('--sleep', type=float, default=0.0,
                   help='seconds between requests (for rate limits)')
    b.set_defaults(func=cmd_build)

    s = sub.add_parser('sample',
                       help='synthesize a phrase with SEVERAL voices, for A/B '
                            'picking (writes one file per voice)')
    s.add_argument('--voices', required=True,
                   help='comma-separated stock voice names, e.g. '
                        'vi-VN-Chirp3-HD-Kore,vi-VN-Chirp3-HD-Aoede')
    s.add_argument('--phrases', default=','.join(DEFAULT_SAMPLE_PHRASES),
                   help='comma-separated texts (default: the speed-limit lines)')
    s.add_argument('--out', default='assets/audio/voice_audition',
                   help='folder to write the samples into')
    s.add_argument('--lang', default='vi-VN')
    s.add_argument('--rate', type=float, default=1.0)
    s.add_argument('--sleep', type=float, default=0.0)
    s.set_defaults(func=cmd_sample)

    w = sub.add_parser('web', help='write an HTML page that plays a folder of clips')
    w.add_argument('--dir', required=True, help='folder with .mp3 clips')
    w.add_argument('--out', required=True, help='html file to write')
    w.add_argument('--title', default=None)
    w.set_defaults(func=cmd_web)

    st = sub.add_parser('site',
                        help='ONE self-contained audition page (clips inlined, '
                             'opens by double-click, no server)')
    st.add_argument('--pack-dir', default='assets/audio/voice_vn_gcp')
    st.add_argument('--audition-dir', default='assets/audio/voice_audition',
                    help='optional multi-voice A/B folder')
    st.add_argument('--out', default='docs/voice_site.html')
    st.add_argument('--title', default='NavBridge — giọng đọc Google Cloud')
    st.add_argument('--rate', default='1.0')
    st.set_defaults(func=cmd_site)

    gv = sub.add_parser('gemini-voices',
                        help='list Gemini TTS voices (prebuilt + Extended Voice '
                             'Library + your designed/replicated ones)')
    gv.set_defaults(func=cmd_gemini_voices)

    wt = sub.add_parser('web-tts',
                        help='Launch interactive Web TTS Studio to test Gemini 3.8 and Chirp 3')
    wt.add_argument('--port', type=int, default=8080, help='Port to bind (default: 8080)')
    wt.add_argument('--no-browser', action='store_true', help='Do not open browser')
    wt.set_defaults(func=lambda args: __import__('web_tts').main())

    args = ap.parse_args()
    return args.func(args)


if __name__ == '__main__':
    raise SystemExit(main())
