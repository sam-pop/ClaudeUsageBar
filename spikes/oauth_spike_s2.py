#!/usr/bin/env python3
"""Phase-0 spike S2: paste-mode variant. Authorize with the manual callback
redirect; the browser displays code#state; the user drops it into
/tmp/claude-spike-code.txt (e.g. `pbpaste > /tmp/claude-spike-code.txt`).
"""
import base64, hashlib, json, os, secrets, subprocess, sys, time, urllib.parse

CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
TOKEN_URL = "https://console.anthropic.com/v1/oauth/token"
USER_AGENT = "ClaudeUsageBar/1.4.0-spike"
MANUAL_REDIRECT = "https://console.anthropic.com/oauth/code/callback"
SCOPE = "user:profile user:inference"
CODE_FILE = "/tmp/claude-spike-code.txt"
OUT_DIR = os.path.expanduser("~/Library/Application Support/ClaudeUsageBarSpike")

def b64url(raw): return base64.urlsafe_b64encode(raw).decode().rstrip("=")

verifier = b64url(secrets.token_bytes(32))
challenge = b64url(hashlib.sha256(verifier.encode()).digest())
state = b64url(secrets.token_bytes(32))

if os.path.exists(CODE_FILE):
    os.remove(CODE_FILE)

params = {"code": "true", "client_id": CLIENT_ID, "response_type": "code",
          "redirect_uri": MANUAL_REDIRECT, "scope": SCOPE,
          "code_challenge": challenge, "code_challenge_method": "S256", "state": state}
url = "https://claude.ai/oauth/authorize?" + urllib.parse.urlencode(params)
print("S2: opening browser with manual redirect. After Authorize, copy the shown code,")
print(f"then run: pbpaste > {CODE_FILE}")
subprocess.run(["open", url])

deadline = time.time() + 600
pasted = None
while time.time() < deadline:
    if os.path.exists(CODE_FILE):
        pasted = open(CODE_FILE).read().strip()
        if pasted:
            break
    time.sleep(2)
if not pasted:
    print("S2 FAIL: no code file within 10 min"); sys.exit(1)

print(f"S2 got pasted input (length {len(pasted)}, contains '#': {'#' in pasted})")
if "#" in pasted:
    code, pasted_state = pasted.split("#", 1)
else:
    code, pasted_state = pasted, state   # observe: some UIs show only the code
print(f"S2 pasted state matches ours: {pasted_state == state}")

body = json.dumps({"grant_type": "authorization_code", "code": code, "state": pasted_state,
                   "client_id": CLIENT_ID, "redirect_uri": MANUAL_REDIRECT,
                   "code_verifier": verifier})
result = subprocess.run(
    ["curl", "-s", "-w", "\n%{http_code}", "-X", "POST", TOKEN_URL,
     "-H", "Content-Type: application/json", "-H", f"User-Agent: {USER_AGENT}",
     "--data-binary", "@-"],
    input=body, capture_output=True, text=True)
payload, status = result.stdout.rsplit("\n", 1)
print(f"S2 exchange: HTTP {status}")
if status != "200":
    print("body:", payload[:300]); sys.exit(1)
grant = json.loads(payload)
print(f"S2 scope = {grant.get('scope')} | refresh_token_expires_in = {grant.get('refresh_token_expires_in')}")
with open(os.path.join(OUT_DIR, "grant3.json"), "w") as f:
    json.dump({"captured_at": time.time(), **grant}, f)
os.chmod(os.path.join(OUT_DIR, "grant3.json"), 0o600)
os.remove(CODE_FILE)
print("S2 COMPLETE (paste-mode flow works)")
