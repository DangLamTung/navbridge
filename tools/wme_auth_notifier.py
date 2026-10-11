#!/usr/bin/env python3
"""WME Session Check, Email Notification & Token Receiver for NavBridge.

When the monthly Waze / WME crawl begins and detects an expired or missing
WME session, this tool sends an email with:
  1. Direct link to Waze Map Editor (https://www.waze.com/editor)
  2. One-click link to the NavBridge WME Auth Portal on the update server
  3. 1-click bookmarklet to instantly transmit the session cookie back to the server
  4. Automatic trigger to launch the crawl & publish fresh data to the NavBridge app.

Usage:
  python3 tools/wme_auth_notifier.py [--check-only] [--email user@example.com] [--server-url http://...] [--preview]
"""

import argparse
import json
import os
import smtplib
import socket
import subprocess
import sys
import urllib.request
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# Read .env if present
ENV_FILE = REPO / ".env"
if ENV_FILE.exists():
    with open(ENV_FILE, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())

DEFAULT_EMAIL = os.environ.get("ALERT_EMAIL", os.environ.get("WME_EMAIL", ""))
SMTP_HOST = os.environ.get("SMTP_HOST", "smtp.gmail.com")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USER = os.environ.get("SMTP_USER", "")
SMTP_PASS = os.environ.get("SMTP_PASS", "")


def get_default_server_url() -> str:
    """Detect public or LAN IP to construct update server link."""
    env_url = os.environ.get("UPDATE_SERVER_URL", os.environ.get("DATA_URL", "")).strip()
    if env_url:
        return env_url.rstrip("/")

    # Detect LAN IP
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        lan_ip = s.getsockname()[0]
        s.close()
        return f"http://{lan_ip}:8089"
    except Exception:
        return "http://127.0.0.1:8089"


def check_wme_session(cookie: str = "") -> bool:
    """Check if WME session is active and can fetch segment data."""
    if not cookie:
        cookie = os.environ.get("WME_COOKIE", "")
        cookie_file = REPO / "tools" / "data" / "wme_cookie.txt"
        if not cookie and cookie_file.exists():
            cookie = cookie_file.read_text(encoding="utf-8").strip()

    if not cookie:
        return False

    test_url = "https://www.waze.com/row-Descartes/app/Features?bbox=106.69,10.77,106.71,10.79"
    req = urllib.request.Request(
        test_url,
        headers={
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)",
            "Cookie": cookie,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=12) as resp:
            data = resp.read()
            if b"login" in resp.url.lower().encode() or resp.status in (401, 403):
                return False
            return len(data) > 100
    except Exception:
        return False


def build_email_content(server_url: str) -> tuple[str, str]:
    """Generate both HTML and Plaintext email bodies."""
    auth_portal_url = f"{server_url}/wme-auth"
    wme_editor_url = "https://www.waze.com/editor"

    # Plain text version
    text_content = f"""[NavBridge] Yêu cầu cấp Token / Đăng nhập Waze để cập nhật bản đồ

Xin chào,

Tiến trình cập nhật tự động đầu tháng của NavBridge cần xác thực phiên đăng nhập WME (Waze Map Editor) để cào dữ liệu biển báo, đoạn đường và giới hạn tốc độ mới nhất.

3 BƯỚC ĐỂ BẮT ĐẦU CÀO DỮ LIỆU TỰ ĐỘNG:
1. Mở Waze Map Editor và đăng nhập: {wme_editor_url}
2. Truy cập cổng cấp Token NavBridge: {auth_portal_url}
3. Dán Cookie hoặc dùng Bookmarklet để gửi Token về Server.

Ngay khi nhận được Token hợp lệ:
- Server sẽ tự động cào dữ liệu Waze + VietMap KC01 + Phạt nguội.
- Đóng gói và phát hành version.json mới.
- Ứng dụng NavBridge sẽ tự động tải dữ liệu mới về điện thoại.

---
NavBridge Auto-Update Robot
"""

    # Rich responsive HTML version
    html_content = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background: #f4f6f9; margin: 0; padding: 20px; color: #333; }}
  .container {{ max-width: 600px; margin: 0 auto; background: #ffffff; border-radius: 12px; overflow: hidden; box-shadow: 0 4px 20px rgba(0,0,0,0.08); }}
  .header {{ background: linear-gradient(135deg, #0288d1, #01579b); color: white; padding: 28px 24px; text-align: center; }}
  .header h1 {{ margin: 0; font-size: 22px; font-weight: 700; }}
  .content {{ padding: 28px 24px; }}
  .step-box {{ background: #f8fafc; border-left: 4px solid #0288d1; border-radius: 4px; padding: 14px 16px; margin: 16px 0; }}
  .step-num {{ font-weight: bold; color: #0288d1; }}
  .btn {{ display: inline-block; padding: 12px 24px; margin: 8px 4px; border-radius: 8px; text-decoration: none; font-weight: 600; font-size: 14px; text-align: center; }}
  .btn-primary {{ background: #0288d1; color: white !important; }}
  .btn-secondary {{ background: #33ccff; color: #002244 !important; }}
  .footer {{ background: #f1f5f9; padding: 16px; text-align: center; font-size: 12px; color: #64748b; }}
  code {{ background: #e2e8f0; padding: 2px 6px; border-radius: 4px; font-size: 12px; font-family: monospace; }}
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <h1>🚗 NavBridge Offline Navigation</h1>
    <p style="margin: 6px 0 0 0; opacity: 0.9; font-size: 14px;">Yêu cầu xác thực WME để tự động cào dữ liệu bản đồ</p>
  </div>
  <div class="content">
    <p>Xin chào,</p>
    <p>Hệ thống crawler của <strong>NavBridge</strong> cần làm mới phiên đăng nhập <strong>WME (Waze Map Editor)</strong> để tiến hành cào dữ liệu biển báo, đoạn đường và tốc độ mới nhất.</p>

    <div class="step-box">
      <span class="step-num">Bước 1:</span> Đăng nhập vào <strong>Waze Map Editor</strong> (nếu chưa đăng nhập):<br>
      <div style="margin-top: 10px;">
        <a href="{wme_editor_url}" target="_blank" class="btn btn-secondary">🌐 Mở Waze Map Editor</a>
      </div>
    </div>

    <div class="step-box">
      <span class="step-num">Bước 2:</span> Mở cổng <strong>NavBridge WME Auth Portal</strong> để cấp Token:<br>
      <div style="margin-top: 10px;">
        <a href="{auth_portal_url}" target="_blank" class="btn btn-primary">🔑 Mở Trang Cấp Token NavBridge</a>
      </div>
    </div>

    <div class="step-box">
      <span class="step-num">Bước 3:</span> Sau khi gửi Token thành công:
      <ul style="margin: 8px 0 0 0; padding-left: 20px; font-size: 13px;">
        <li>Server sẽ <strong>tự động cào dữ liệu</strong> và deduplicate với VietMap KC01.</li>
        <li>Phát hành <code>version.json</code> mới lên <strong>DATA_URL</strong>.</li>
        <li>Ứng dụng <strong>NavBridge trên điện thoại</strong> sẽ tự động tải về ngay khi mở máy!</li>
      </ul>
    </div>
  </div>
  <div class="footer">
    NavBridge Auto-Update Robot &bull; Endpoint: <code>{server_url}</code>
  </div>
</div>
</body>
</html>
"""
    return text_content, html_content


def send_verification_email(recipient: str, server_url: str = "") -> bool:
    """Send verification email alert to the user."""
    if not recipient:
        recipient = DEFAULT_EMAIL
    if not recipient:
        print("[WME Auth] ERROR: No recipient email specified (set ALERT_EMAIL or pass --email).", file=sys.stderr)
        return False

    server_url = server_url or get_default_server_url()
    subject = "[NavBridge] 🔑 Đăng nhập Waze để cấp Token cho Server tự động cập nhật"
    text_body, html_body = build_email_content(server_url)

    # 1. Try sending via SMTP
    if SMTP_USER and SMTP_PASS:
        try:
            msg = MIMEMultipart("alternative")
            msg["From"] = SMTP_USER
            msg["To"] = recipient
            msg["Subject"] = subject
            msg.attach(MIMEText(text_body, "plain", "utf-8"))
            msg.attach(MIMEText(html_body, "html", "utf-8"))

            with smtplib.SMTP(SMTP_HOST, SMTP_PORT) as server:
                server.starttls()
                server.login(SMTP_USER, SMTP_PASS)
                server.send_message(msg)
            print(f"[WME Auth] ✅ Verification email successfully sent to {recipient} via SMTP ({SMTP_HOST}).")
            return True
        except Exception as e:
            print(f"[WME Auth] SMTP error: {e}", file=sys.stderr)

    # 2. Try sending via local mail command
    for cmd in ["mail", "mailx"]:
        if subprocess.call(["which", cmd], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0:
            try:
                p = subprocess.Popen([cmd, "-s", subject, recipient], stdin=subprocess.PIPE, text=True)
                p.communicate(input=text_body)
                if p.returncode == 0:
                    print(f"[WME Auth] ✅ Verification email sent to {recipient} via local '{cmd}'.")
                    return True
            except Exception:
                pass

    print(f"\n[WME Auth] =====================================================================")
    print(f"[WME Auth] YÊU CẦU CẤP TOKEN WAZE WME:")
    print(f"[WME Auth] Gửi tới:       {recipient}")
    print(f"[WME Auth] WME Auth URL:  {server_url}/wme-auth")
    print(f"[WME Auth] Waze Editor:   https://www.waze.com/editor")
    print(f"[WME Auth] (Để gửi email tự động qua Gmail, hãy thêm SMTP_USER & SMTP_PASS vào .env)")
    print(f"[WME Auth] =====================================================================\n")
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-only", action="store_true", help="Only check WME session status")
    parser.add_argument("--email", default=DEFAULT_EMAIL, help="Recipient email address")
    parser.add_argument("--server-url", default="", help="NavBridge Update Server URL")
    parser.add_argument("--preview", action="store_true", help="Preview email content to stdout / file")
    parser.add_argument("--force-mail", action="store_true", help="Force send notification email")
    args = parser.parse_args()

    server_url = args.server_url or get_default_server_url()

    if args.preview:
        text, html = build_email_content(server_url)
        print("=== Plain Text Version ===")
        print(text)
        preview_file = REPO / "update" / "wme_mail_preview.html"
        preview_file.parent.mkdir(parents=True, exist_ok=True)
        preview_file.write_text(html, encoding="utf-8")
        print(f"\nHTML preview saved to: {preview_file}")
        sys.exit(0)

    is_valid = check_wme_session()
    if is_valid and not args.force_mail:
        print("[WME Auth] WME session is active and valid.")
        sys.exit(0)

    print("[WME Auth] WME session expired or needs re-authentication.")
    if not args.check_only or args.force_mail:
        send_verification_email(args.email, server_url)
    sys.exit(1)


if __name__ == "__main__":
    main()
