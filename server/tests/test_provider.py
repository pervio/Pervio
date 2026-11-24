#!/usr/bin/env python3
"""Regression tests for server/bin/pervio-provider — the Mac's roster of
third-party model providers and the Claude setup-token writer. Hermetic:
isolated $HOME. Covers add/list/remove (0600 files, never a key in `list`),
the shell overlay for claude (ANTHROPIC_* exports) and codex (-c overrides +
the key's env var), discovery of ~/.claude/settings.json and
~/.codex/config.toml, bad inputs, and claude-token write/clear."""
import base64
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
BIN = os.path.realpath(os.path.join(HERE, "..", "bin"))
PROV = os.path.join(BIN, "pervio-provider")
results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + (("  [" + str(detail)[:240] + "]") if (detail and not cond) else ""))


def b64(o):
    return base64.b64encode(json.dumps(o).encode()).decode()


home = tempfile.mkdtemp(prefix="pprov_home_", dir="/tmp")
env = dict(os.environ, HOME=home)


def run(*args):
    return subprocess.run([sys.executable, PROV] + list(args), env=env, capture_output=True, text=True, timeout=30)


print("=== add / list / remove ===")
p = run("list")
check("P1 an empty roster lists as []", p.returncode == 0 and json.loads(p.stdout) == [], p.stdout)
p = run("add", "--b64", b64({"name": "GLM", "engine": "claude", "label": "智谱 GLM",
                             "baseUrl": "https://open.bigmodel.cn/api/anthropic", "apiKey": "sk-secret-1",
                             "models": ["glm-5", "glm-5-air"]}))
lst = json.loads(p.stdout) if p.returncode == 0 else []
check("P2 add writes a provider (name lower-cased) and prints the roster",
      p.returncode == 0 and [x["name"] for x in lst] == ["glm"] and lst[0]["engine"] == "claude"
      and lst[0]["models"] == ["glm-5", "glm-5-air"] and lst[0]["defaultModel"] == "glm-5" and lst[0]["hasKey"] is True,
      (p.returncode, p.stderr[:200], lst))
check("P2a the roster never carries the key", "sk-secret-1" not in p.stdout)
fp = os.path.join(home, ".pervio", "providers", "glm.env")
mode = stat.S_IMODE(os.stat(fp).st_mode)
check("P2b the file is owner-only (0600) in an owner-only dir",
      mode == 0o600 and stat.S_IMODE(os.stat(os.path.dirname(fp)).st_mode) == 0o700, oct(mode))
p = run("add", "--b64", b64({"name": "kimi", "engine": "codex", "label": "Kimi",
                             "baseUrl": "https://api.moonshot.cn/v1", "apiKey": "sk-secret-2",
                             "models": "kimi-k2,kimi-k2-turbo", "defaultModel": "kimi-k2-turbo", "wireApi": "chat"}))
lst = json.loads(p.stdout) if p.returncode == 0 else []
check("P3 a codex provider: models as a comma string, explicit default, wire api",
      p.returncode == 0 and len(lst) == 2 and lst[1]["engine"] == "codex" and lst[1]["defaultModel"] == "kimi-k2-turbo"
      and lst[1]["models"] == ["kimi-k2", "kimi-k2-turbo"] and lst[1]["wireApi"] == "chat", (p.stderr[:200], lst))
p = run("add", "--b64", b64({"name": "glm", "engine": "claude", "baseUrl": "https://open.bigmodel.cn/api/anthropic",
                             "models": ["glm-5"]}))
check("P3a re-adding without a key keeps the stored key", p.returncode == 0 and json.loads(p.stdout)[0]["hasKey"] is True, p.stderr[:200])

print("=== bad inputs ===")
for name, spec in (("bad name", {"name": "Bad Name!", "engine": "claude", "baseUrl": "https://x", "apiKey": "k"}),
                   ("bad engine", {"name": "x", "engine": "cursor", "baseUrl": "https://x", "apiKey": "k"}),
                   ("bad url", {"name": "x", "engine": "claude", "baseUrl": "open.bigmodel.cn", "apiKey": "k"}),
                   ("no key", {"name": "newone", "engine": "claude", "baseUrl": "https://x"})):
    p = run("add", "--b64", b64(spec))
    check("P4 %s is refused (exit 4)" % name, p.returncode == 4, (p.returncode, p.stderr[:120]))

print("=== shell overlay ===")
p = run("shell", "--name", "glm", "--engine", "claude")
check("P5 claude provider → ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN exports and the default model",
      p.returncode == 0 and "export ANTHROPIC_BASE_URL=https://open.bigmodel.cn/api/anthropic" in p.stdout
      and "export ANTHROPIC_AUTH_TOKEN=sk-secret-1" in p.stdout and "PERVIO_PROVIDER_DEFAULT_MODEL=glm-5" in p.stdout,
      p.stdout)
p = run("shell", "--name", "kimi", "--engine", "codex")
check("P6 codex provider → the key in its own env var and -c model_provider overrides",
      p.returncode == 0 and "export PERVIO_PROVIDER_KEY_KIMI=sk-secret-2" in p.stdout
      and "model_provider=\"pervio_kimi\"" in p.stdout and "base_url=\"https://api.moonshot.cn/v1\"" in p.stdout
      and "env_key=\"PERVIO_PROVIDER_KEY_KIMI\"" in p.stdout and "wire_api=\"chat\"" in p.stdout
      and "PERVIO_PROVIDER_DEFAULT_MODEL=kimi-k2-turbo" in p.stdout, p.stdout)
# the array line must be valid bash
sh = subprocess.run(["bash", "-c", p.stdout + '\necho "${#PERVIO_CODEX_PROVIDER_ARGS[@]} ${PERVIO_CODEX_PROVIDER_ARGS[1]}"'],
                    capture_output=True, text=True)
check("P6a the overlay evals in bash: 10 array elements, the first -c value intact",
      sh.stdout.strip() == '10 model_provider="pervio_kimi"', sh.stdout + sh.stderr)
p = run("shell", "--name", "glm", "--engine", "codex")
check("P7 asking a claude provider for codex is refused", p.returncode == 4, p.returncode)
p = run("shell", "--name", "nope", "--engine", "claude")
check("P7a unknown provider is refused (exit 4)", p.returncode == 4 and "not found" in p.stderr, (p.returncode, p.stderr))

print("=== discovery ===")
os.makedirs(os.path.join(home, ".claude"), exist_ok=True)
with open(os.path.join(home, ".claude", "settings.json"), "w") as f:
    json.dump({"env": {"ANTHROPIC_BASE_URL": "https://api.minimax.io/anthropic", "ANTHROPIC_AUTH_TOKEN": "mm-key",
                       "ANTHROPIC_MODEL": "MiniMax-M2"}}, f)
os.makedirs(os.path.join(home, ".codex"), exist_ok=True)
with open(os.path.join(home, ".codex", "config.toml"), "w") as f:
    f.write('model = "gpt-5"\n[model_providers.deepseek]\nname = "DeepSeek"\nbase_url = "https://api.deepseek.com/v1"\n'
            'env_key = "DEEPSEEK_API_KEY"\nwire_api = "chat"\n[profiles.x]\nmodel = "y"\n')
with open(os.path.join(home, ".pervio", "credentials.env"), "w") as f:
    f.write("DEEPSEEK_API_KEY='ds-key'\n")
lst = json.loads(run("list").stdout)
names = {x["name"]: x for x in lst}
check("P8 settings.json with ANTHROPIC_BASE_URL shows up as claude-settings, model from ANTHROPIC_MODEL, key seen",
      names.get("claude-settings", {}).get("baseUrl") == "https://api.minimax.io/anthropic"
      and names["claude-settings"]["defaultModel"] == "MiniMax-M2" and names["claude-settings"]["hasKey"] is True, lst)
check("P9 codex config.toml's model_providers show up as codex:<name>, key resolved from credentials.env",
      names.get("codex:deepseek", {}).get("baseUrl") == "https://api.deepseek.com/v1"
      and names["codex:deepseek"]["hasKey"] is True and names["codex:deepseek"]["label"] == "DeepSeek", lst)
p = run("shell", "--name", "claude-settings", "--engine", "claude")
check("P10 claude-settings overlay exports every ANTHROPIC_* of that env block",
      "export ANTHROPIC_BASE_URL=https://api.minimax.io/anthropic" in p.stdout and "export ANTHROPIC_AUTH_TOKEN=mm-key" in p.stdout
      and "PERVIO_PROVIDER_DEFAULT_MODEL=MiniMax-M2" in p.stdout, p.stdout)
p = run("shell", "--name", "codex:deepseek", "--engine", "codex")
check("P11 codex-config overlay exports the named key and only -c model_provider",
      "export DEEPSEEK_API_KEY=ds-key" in p.stdout and 'model_provider="deepseek"' in p.stdout and "base_url" not in p.stdout, p.stdout)

print("=== remove ===")
p = run("remove", "--name", "kimi")
check("P12 remove drops the file and prints the roster without it",
      p.returncode == 0 and "kimi" not in [x["name"] for x in json.loads(p.stdout)]
      and not os.path.exists(os.path.join(home, ".pervio", "providers", "kimi.env")), p.stdout)

print("=== cursor-key ===")
p = run("cursor-key", "--b64", base64.b64encode(b"key_cursor_123").decode())
_credp = os.path.join(home, ".pervio", "credentials.env")
ck = open(_credp).read() if p.returncode == 0 and os.path.exists(_credp) else ""
check("P13c cursor-key writes CURSOR_API_KEY into credentials.env (0600) and reports it",
      p.returncode == 0 and json.loads(p.stdout).get("cursorKey") is True and "CURSOR_API_KEY=key_cursor_123\n" in ck
      and stat.S_IMODE(os.stat(_credp).st_mode) == 0o600, (p.returncode, p.stdout, p.stderr[:120], ck))
p = run("cursor-key", "--clear")
ck = open(_credp).read()
check("P13d cursor-key --clear removes it", p.returncode == 0 and "CURSOR_API_KEY" not in ck, ck)

print("=== cursor-login (file store, link on the phone) ===")
SHIM = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "shim"))
done_flag = os.path.join(home, "login-done")
env_login = dict(env, PATH=SHIM + ":" + env.get("PATH", ""), SHIM_CURSOR_LOGIN_DONE=done_flag)
def run_login(*args, extra=None):
    e = dict(env_login, **(extra or {}))
    return subprocess.run([sys.executable, PROV, "cursor-login"] + list(args), env=e, capture_output=True, text=True, timeout=40)
p = run_login("--status")
st = json.loads(p.stdout) if p.returncode == 0 else {}
check("P14 before anything the login state is idle, no file login", st.get("state") == "idle" and st.get("login") is False, (p.returncode, p.stdout, p.stderr[-200:]))
p = run_login("--start")
st = json.loads(p.stdout) if p.returncode == 0 else {}
check("P14a --start launches `agent login` on the file store with the browser suppressed and returns the link",
      st.get("state") == "waiting" and st.get("url", "").startswith("https://cursor.com/loginDeepControl?"), (p.returncode, p.stdout, p.stderr[-200:]))
p = run_login("--status")
st2 = json.loads(p.stdout) if p.returncode == 0 else {}
check("P14b --status while the person has not signed in: waiting, same link", st2.get("state") == "waiting" and st2.get("url") == st.get("url"), st2)
open(done_flag, "w").close()      # the person signed in on the phone
import time as _t
for _ in range(50):
    st3 = json.loads(run_login("--status").stdout)
    if st3.get("state") == "done":
        break
    _t.sleep(0.2)
check("P14c once the browser sign-in completes: done, the account named, ~/.cursor/auth.json on disk (0600)",
      st3.get("state") == "done" and st3.get("account") == "shim@example.com" and st3.get("login") is True
      and stat.S_IMODE(os.stat(os.path.join(home, ".cursor", "auth.json")).st_mode) == 0o600, st3)
os.remove(done_flag)
p = run_login("--start", extra={"SHIM_CURSOR_LOGIN_FAIL": "1"})
_t.sleep(0.5)
st4 = json.loads(run_login("--status").stdout)
check("P14d a login that dies reports failed with the agent's last line", st4.get("state") == "failed" and "login failed" in st4.get("error", ""), st4)
p = run_login("--start")
st5 = json.loads(p.stdout)
p = run_login("--cancel")
st6 = json.loads(p.stdout)
check("P14e --cancel stops a waiting login", st5.get("state") == "waiting" and st6.get("state") == "idle", (st5, st6))
p = subprocess.run([sys.executable, PROV, "cursor-login", "--start"], env=dict(env, PATH="/nonexistent"), capture_output=True, text=True, timeout=30)
check("P14f no cursor agent on the Mac: a plain refusal, exit 4", p.returncode == 4 and "not found" in p.stderr, (p.returncode, p.stderr[-200:]))
shutil.rmtree(os.path.join(home, ".cursor"), ignore_errors=True)

print("=== claude-token ===")
p = run("claude-token", "--b64", base64.b64encode(b"sk-ant-oat01-abc").decode())
cred = open(os.path.join(home, ".pervio", "credentials.env")).read()
check("P13 claude-token writes CLAUDE_CODE_OAUTH_TOKEN into credentials.env, keeping other lines",
      p.returncode == 0 and json.loads(p.stdout) == {"claudeToken": True} and "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-abc" in cred
      and "DEEPSEEK_API_KEY=ds-key" in cred, (p.stdout, cred))
check("P13a credentials.env is 0600", stat.S_IMODE(os.stat(os.path.join(home, ".pervio", "credentials.env")).st_mode) == 0o600)
p = run("claude-token", "--b64", base64.b64encode(b"has space").decode())
check("P13b a token with whitespace is refused", p.returncode == 4, p.returncode)
p = run("claude-token", "--clear")
cred = open(os.path.join(home, ".pervio", "credentials.env")).read()
check("P14 --clear removes the token and keeps the rest",
      json.loads(p.stdout) == {"claudeToken": False} and "CLAUDE_CODE_OAUTH_TOKEN" not in cred and "DEEPSEEK_API_KEY" in cred, cred)

print("=== presets / regions / live models ===")
p = run("presets")
presets = json.loads(p.stdout) if p.returncode == 0 else []
check("P15 presets lists the vendor table with regions and URLs",
      p.returncode == 0 and {x["id"] for x in presets} >= {"glm", "kimi", "minimax", "deepseek", "qwen", "openrouter"}
      and all(all(r.get("claudeUrl", "").startswith("https://") and r.get("codexUrl", "").startswith("https://") for r in x["regions"]) for x in presets),
      [x.get("id") for x in presets])
p = run("add", "--b64", b64({"preset": "glm", "engine": "claude", "apiKey": "k-glm"}))
check("P16 a preset with several regions refuses an add without a region (exit 4)", p.returncode == 4 and "region" in p.stderr, (p.returncode, p.stderr[:120]))
p = run("add", "--b64", b64({"preset": "glm", "region": "intl", "engine": "claude", "apiKey": "k-glm"}))
lst = json.loads(p.stdout) if p.returncode == 0 else []
g = next((x for x in lst if x["name"] == "glm"), {})
check("P17 preset + region fills the name, label, the region's Claude URL, the vendor's models and default",
      p.returncode == 0 and g.get("baseUrl") == "https://api.z.ai/api/anthropic" and g.get("label") == "智谱 GLM"
      and g.get("defaultModel") == "glm-5.3" and "glm-5.2" in g.get("models", []) and g.get("preset") == "glm"
      and g.get("region") == "intl" and g.get("modelsSource") == "preset", (p.returncode, p.stderr[:160], g))
p = run("add", "--b64", b64({"preset": "deepseek", "engine": "codex", "apiKey": "k-ds"}))
d = next((x for x in json.loads(p.stdout) if x["name"] == "deepseek"), {}) if p.returncode == 0 else {}
check("P18 a single-region preset needs no region; codex takes the OpenAI-compatible URL and the chat wire api",
      d.get("baseUrl") == "https://api.deepseek.com/v1" and d.get("wireApi") == "chat" and d.get("region") == "global", (p.stderr[:120], d))
p = run("add", "--b64", b64({"preset": "kimi", "region": "cn", "engine": "claude", "apiKey": "k", "name": "kimi-cn", "models": ["kimi-k3"]}))
k = next((x for x in json.loads(p.stdout) if x["name"] == "kimi-cn"), {}) if p.returncode == 0 else {}
check("P19 what the person typed wins over the preset (own name, own model list)",
      k.get("models") == ["kimi-k3"] and k.get("modelsSource") == "manual" and k.get("baseUrl") == "https://api.moonshot.cn/anthropic", k)

# a fake vendor answering /models, to prove the live fetch and the Bearer header
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
seen = {}
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        seen["auth"] = self.headers.get("Authorization"); seen["path"] = self.path
        body = json.dumps({"object": "list", "data": [{"id": "vendor-pro"}, {"id": "vendor-flash"}, {"id": "glm-5.3"}]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = HTTPServer(("127.0.0.1", 0), H); port = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()
p = run("add", "--b64", b64({"preset": "glm", "region": "cn", "engine": "claude", "apiKey": "k-live",
                             "modelsUrl": "http://127.0.0.1:%d/v1/models" % port, "fetchModels": True, "name": "glm-live"}))
g = next((x for x in json.loads(p.stdout) if x["name"] == "glm-live"), {}) if p.returncode == 0 else {}
check("P20 fetchModels asks the vendor's /models with the key and keeps what it says; the default survives when still offered",
      seen.get("auth") == "Bearer k-live" and seen.get("path") == "/v1/models"
      and g.get("models") == ["vendor-pro", "vendor-flash", "glm-5.3"] and g.get("defaultModel") == "glm-5.3"
      and g.get("modelsSource") == "live", (p.stderr[:160], seen, g))
seen.clear()
p = run("refresh", "--name", "glm-live")
check("P21 refresh asks again with the stored key", p.returncode == 0 and seen.get("auth") == "Bearer k-live", (p.returncode, p.stderr[:120], seen))
p = run("refresh", "--name", "kimi-cn")
check("P21a refresh on a provider whose vendor does not answer fails loudly (exit 5)", p.returncode == 5, (p.returncode, p.stderr[:120]))
srv.shutdown()
# Editing = re-adding under the same name (the app's edit form): no key keeps the
# stored one, unchanged model names keep their "live" mark, a new URL lands.
p = run("add", "--b64", b64({"name": "glm-live", "preset": "glm", "region": "intl", "engine": "claude",
                             "baseUrl": "https://api.z.ai/api/anthropic", "models": ["vendor-pro", "vendor-flash", "glm-5.3"],
                             "defaultModel": "glm-5.3", "label": "GLM (intl)"}))
g = next((x for x in json.loads(p.stdout) if x["name"] == "glm-live"), {}) if p.returncode == 0 else {}
check("P21b an edit without a key and with the same model names keeps the key and the live mark, takes the new URL/label/region",
      p.returncode == 0 and g.get("hasKey") is True and g.get("modelsSource") == "live" and g.get("region") == "intl"
      and g.get("baseUrl") == "https://api.z.ai/api/anthropic" and g.get("label") == "GLM (intl)", (p.returncode, p.stderr[:160], g))
p = run("add", "--b64", b64({"name": "glm-live", "engine": "claude", "baseUrl": "https://api.z.ai/api/anthropic",
                             "models": ["glm-5.3", "glm-5.2"]}))
g = next((x for x in json.loads(p.stdout) if x["name"] == "glm-live"), {}) if p.returncode == 0 else {}
check("P21c an edit that changes the model names marks them typed (manual)",
      p.returncode == 0 and g.get("models") == ["glm-5.3", "glm-5.2"] and g.get("modelsSource") == "manual", (p.stderr[:120], g))
p = run("add", "--b64", b64({"preset": "nope", "engine": "claude", "apiKey": "k", "baseUrl": "https://x.example"}))
check("P22 an unknown preset is refused by name (exit 4), not silently ignored", p.returncode == 4 and "unknown preset" in p.stderr, (p.returncode, p.stderr[:120]))

print("=== the Anthropic login never travels to a third party ===")
p = run("shell", "--name", "glm", "--engine", "claude")
sh = subprocess.run(["bash", "-c", "export CLAUDE_CODE_OAUTH_TOKEN=secret-oauth; export ANTHROPIC_API_KEY=sk-mine\n" + p.stdout
                     + "\nprintf '%s|%s|%s' \"${ANTHROPIC_API_KEY-unset}\" \"${CLAUDE_CODE_OAUTH_TOKEN-unset}\" \"$ANTHROPIC_AUTH_TOKEN\""],
                    capture_output=True, text=True)
check("P23 claude overlay blanks ANTHROPIC_API_KEY (empty string, as OpenRouter requires) and drops the setup-token",
      sh.stdout == "|unset|k-glm", sh.stdout + sh.stderr)

shutil.rmtree(home, ignore_errors=True)
ok = all(results)
print("\n=== pervio-provider: %s (%d/%d) ===" % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
