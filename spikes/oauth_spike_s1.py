#!/usr/bin/env python3
"""Phase-0 spike S1: authorize (localhost redirect) -> code exchange -> endpoint checks.

Prints structural findings only (field names, expiries, scopes, HTTP statuses).
Never prints token/code/verifier values. Tokens persist to a chmod-600 file
OUTSIDE the repo for later spike steps (S6 eviction, S7 renewal, S11 T+72h).

HTTPS goes through curl (framework Python here lacks SSL certs).
"""
import base64, hashlib, http.server, json, os, secrets, socketserver, subprocess, sys, time, urllib.parse

CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
AUTHORIZE_HOST = sys.argv[1] if len(sys.argv) > 1 else "https://claude.ai"
TOKEN_URL = "https://console.anthropic.com/v1/oauth/token"
USER_AGENT = "ClaudeUsageBar/1.4.0-spike"
SCOPE = os.environ.get("SPIKE_SCOPE", "org:create_api_key user:profile user:inference")
OUT_DIR = os.path.expanduser("~/Library/Application Support/ClaudeUsageBarSpike")
GRANT_FILE = os.path.join(OUT_DIR, os.environ.get("SPIKE_GRANT_NAME", "grant1") + ".json")

def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")

verifier = b64url(secrets.token_bytes(32))
challenge = b64url(hashlib.sha256(verifier.encode("ascii")).digest())
state = b64url(secrets.token_bytes(32))

class Handler(http.server.BaseHTTPRequestHandler):
    captured = {}
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        ok = (parsed.path == "/callback"
              and query.get("code")
              and query.get("state", [""])[0] == state)
        if ok:
            Handler.captured["code"] = query["code"][0]
            Handler.captured["extra_params"] = sorted(k for k in query if k not in ("code", "state"))
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(b"<h2>Spike S1 succeeded &mdash; you can close this tab.</h2>")
        else:
            self.send_response(404)
            self.end_headers()
        Handler.captured.setdefault("requests_seen", []).append(parsed.path)
    def log_message(self, *args):
        pass

server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
port = server.server_address[1]
redirect_uri = f"http://localhost:{port}/callback"

params = {
    "code": "true",
    "client_id": CLIENT_ID,
    "response_type": "code",
    "redirect_uri": redirect_uri,
    "scope": SCOPE,
    "code_challenge": challenge,
    "code_challenge_method": "S256",
    "state": state,
}
authorize_url = AUTHORIZE_HOST + "/oauth/authorize?" + urllib.parse.urlencode(params)
print(f"S1: listener on port {port}; opening browser at {AUTHORIZE_HOST}/oauth/authorize (scope: {SCOPE})")
subprocess.run(["open", authorize_url])

server.timeout = 5
deadline = time.time() + 300
while "code" not in Handler.captured and time.time() < deadline:
    server.handle_request()
server.server_close()

if "code" not in Handler.captured:
    print("S1 FAIL: no valid callback within 300s.")
    print("requests seen by listener:", Handler.captured.get("requests_seen", []))
    sys.exit(1)

print("S1 callback OK. Non-code/state params on redirect:", Handler.captured["extra_params"])
print("requests seen by listener:", Handler.captured.get("requests_seen", []))

body = json.dumps({
    "grant_type": "authorization_code",
    "code": Handler.captured["code"],
    "state": state,
    "client_id": CLIENT_ID,
    "redirect_uri": redirect_uri,
    "code_verifier": verifier,
})
# Auth codes live for minutes; a 429 (seen when the app was hammering refreshes
# from this IP) is worth waiting out rather than burning the code.
for attempt, delay in enumerate((0, 30, 60, 90)):
    if delay:
        print(f"exchange retry {attempt} after {delay}s (rate limited)")
        time.sleep(delay)
    result = subprocess.run(
        ["curl", "-s", "-w", "\n%{http_code} %{url_effective}", "-X", "POST", TOKEN_URL,
         "-H", "Content-Type: application/json", "-H", f"User-Agent: {USER_AGENT}", "--data-binary", "@-"],
        input=body, capture_output=True, text=True)
    payload, tail = result.stdout.rsplit("\n", 1)
    status, final_url = tail.split(" ", 1)
    if status != "429":
        break
print(f"exchange: HTTP {status} at {final_url}")
if status != "200":
    print("exchange FAIL body (first 400 chars):", payload[:400])
    sys.exit(1)

grant = json.loads(payload)
SAFE_KEYS = ("expires_in", "refresh_token_expires_in", "scope", "token_type", "organization", "account")
print("exchange response keys:", sorted(grant.keys()))
for key in SAFE_KEYS:
    if key in grant:
        print(f"  {key} = {grant[key]}")

os.makedirs(OUT_DIR, mode=0o700, exist_ok=True)
with open(GRANT_FILE, "w") as f:
    json.dump({"captured_at": time.time(), "redirect_uri": redirect_uri,
               "scope": SCOPE, **grant}, f)
os.chmod(GRANT_FILE, 0o600)
print(f"tokens saved (600) to: {GRANT_FILE}")

token = grant["access_token"]
for name, url, headers in [
    ("usage", "https://api.anthropic.com/oauth/usage", []),
    ("profile", "https://api.anthropic.com/api/oauth/profile", ["anthropic-beta: oauth-2025-04-20"]),
]:
    cmd = ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", url,
           "-H", "accept: application/json", "-H", f"User-Agent: {USER_AGENT}"]
    for h in headers:
        cmd += ["-H", h]
    cmd += ["-H", "@-"]
    check = subprocess.run(cmd, input=f"authorization: Bearer {token}", capture_output=True, text=True)
    print(f"S5 {name} endpoint: HTTP {check.stdout.strip()}")

ident = subprocess.run(
    ["curl", "-s", "https://api.anthropic.com/api/oauth/profile",
     "-H", "accept: application/json", "-H", "anthropic-beta: oauth-2025-04-20", "-H", f"User-Agent: {USER_AGENT}", "-H", "@-"],
    input=f"authorization: Bearer {token}", capture_output=True, text=True)
try:
    account = json.loads(ident.stdout).get("account", {})
    print("granted identity:", account.get("email"), "| uuid:", account.get("uuid"))
except Exception:
    print("identity parse failed (first 200 chars):", ident.stdout[:200])
print("S1 COMPLETE")
