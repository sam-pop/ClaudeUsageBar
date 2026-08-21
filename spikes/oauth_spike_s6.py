#!/usr/bin/env python3
"""Phase-0 spike S6+S7+S9: second login for the same account (with login_hint),
then exercise grant1's refresh token to test eviction and expiry renewal.

Prints structural findings only; never prints token/code values.
"""
import base64, hashlib, http.server, json, os, secrets, socketserver, subprocess, sys, time, urllib.parse

CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
TOKEN_URL = "https://console.anthropic.com/v1/oauth/token"
USER_AGENT = "ClaudeUsageBar/1.4.0-spike"
SCOPE = "user:profile user:inference"      # request exactly what S1 showed gets granted
OUT_DIR = os.path.expanduser("~/Library/Application Support/ClaudeUsageBarSpike")

def b64url(raw): return base64.urlsafe_b64encode(raw).decode().rstrip("=")

with open(os.path.join(OUT_DIR, "grant1.json")) as f:
    grant1 = json.load(f)
hint = grant1["account"]["email_address"]

verifier = b64url(secrets.token_bytes(32))
challenge = b64url(hashlib.sha256(verifier.encode()).digest())
state = b64url(secrets.token_bytes(32))

class Handler(http.server.BaseHTTPRequestHandler):
    captured = {}
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        if (parsed.path == "/callback" and query.get("code")
                and query.get("state", [""])[0] == state):
            Handler.captured["code"] = query["code"][0]
            self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers()
            self.wfile.write(b"<h2>Spike S6 succeeded &mdash; close this tab.</h2>")
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *args): pass

server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
port = server.server_address[1]
redirect_uri = f"http://localhost:{port}/callback"
params = {"code": "true", "client_id": CLIENT_ID, "response_type": "code",
          "redirect_uri": redirect_uri, "scope": SCOPE,
          "code_challenge": challenge, "code_challenge_method": "S256",
          "state": state, "login_hint": hint}
url = "https://claude.ai/oauth/authorize?" + urllib.parse.urlencode(params)
print(f"S6: opening browser (port {port}, login_hint={hint}) — S9: note whether the account is preselected")
subprocess.run(["open", url])

server.timeout = 5
deadline = time.time() + 300
while "code" not in Handler.captured and time.time() < deadline:
    server.handle_request()
server.server_close()
if "code" not in Handler.captured:
    print("S6 FAIL: no callback in 300s"); sys.exit(1)

def token_post(body: dict):
    result = subprocess.run(
        ["curl", "-s", "-w", "\n%{http_code}", "-X", "POST", TOKEN_URL,
         "-H", "Content-Type: application/json", "-H", f"User-Agent: {USER_AGENT}",
         "--data-binary", "@-"],
        input=json.dumps(body), capture_output=True, text=True)
    payload, status = result.stdout.rsplit("\n", 1)
    return status, payload

status, payload = token_post({
    "grant_type": "authorization_code", "code": Handler.captured["code"], "state": state,
    "client_id": CLIENT_ID, "redirect_uri": redirect_uri, "code_verifier": verifier})
print(f"grant2 exchange: HTTP {status}")
if status != "200":
    print("body:", payload[:300]); sys.exit(1)
grant2 = json.loads(payload)
print(f"grant2 scope = {grant2.get('scope')} | refresh_token_expires_in = {grant2.get('refresh_token_expires_in')}")
with open(os.path.join(OUT_DIR, "grant2.json"), "w") as f:
    json.dump({"captured_at": time.time(), **grant2}, f)
os.chmod(os.path.join(OUT_DIR, "grant2.json"), 0o600)

# S6: is grant1 still alive after grant2's login?
status, payload = token_post({
    "grant_type": "refresh_token", "refresh_token": grant1["refresh_token"],
    "client_id": CLIENT_ID})
print(f"S6 grant1 refresh after grant2 login: HTTP {status}")
if status == "200":
    refreshed = json.loads(payload)
    print("S6 VERDICT: grants COEXIST (no eviction)")
    before, after = grant1.get("refresh_token_expires_in"), refreshed.get("refresh_token_expires_in")
    print(f"S7: refresh_token_expires_in before={before} after={after} "
          f"-> {'RENEWED (rolling window)' if after and after >= 2300000 else 'NOT renewed (absolute expiry)'}")
    grant1.update(refreshed)   # rotation: persist the new refresh token or grant1 dies
    with open(os.path.join(OUT_DIR, "grant1.json"), "w") as f:
        json.dump(grant1, f)
    os.chmod(os.path.join(OUT_DIR, "grant1.json"), 0o600)
    print("grant1 rotated tokens persisted")
else:
    print("body:", payload[:300])
    print("S6 VERDICT: grant1 EVICTED by second login -> design must revoke-then-replace")
print("S6/S7/S9 COMPLETE")
