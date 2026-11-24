"""_pervio_lib — child-agent execution shared by pervio-dispatch (LLM-initiated,
gated by depth/concurrency/budget) and pervio-orchestrate fan-out (orchestrator-
initiated, ungated; the caller caps N). Import-safe: no argv/env reads at import,
NO sys.exit (so it's safe to call from inside a ThreadPool worker — a sys.exit
there would raise SystemExit and crash the collect loop)."""
import json
import os
import re
import shutil
import signal
import subprocess

BANNED = {"bypassPermissions", "danger-full-access"}      # never granted to a child
DEFAULT_TOOLS = "Bash,Read,Write,Edit,MultiEdit,Glob,Grep"   # excludes Task/CronCreate

# Model TIERS (WF-4): a spec may say what it WANTS ("flagship") instead of a
# frozen model id; this table says what that means today. Model churn becomes
# one edit here instead of surgery on every saved spec and schedule. Raw ids
# (and codex models) pass through untouched — power users lose nothing.
MODEL_TIERS = {
    "frontier": "claude-fable-5-1",      # the hardest judgement calls only — own weekly quota, top price
    "flagship": "claude-opus-5",         # deep judgement: verify/revise/editorial
    "balanced": "claude-sonnet-5",       # bulk reading and scoring
    "fast": "claude-haiku-4-5-20251001", # cheap mechanical turns
}

# The chat pickers' menu (2026-09-08). The phone reads this ONCE per connect
# (`pervio-orchestrate models`), caches it, and shows it in the model quick-picks
# — so a new model is one line here, no app release. Codex's config default
# (~/.codex/config.toml) is deliberately NOT changed by this table: astra is a
# per-conversation pick until the user says otherwise.
CHAT_MODELS = {
    "claude": [
        {"id": "claude-opus-5",             "note": "recommended"},
        {"id": "claude-fable-5-1",          "note": "most capable · own weekly quota"},
        {"id": "claude-sonnet-5",           "note": "faster, cheaper"},
        {"id": "claude-haiku-4-5-20251001", "note": "fast, cheap"},
        {"id": "opus",                      "note": "alias: the family's latest (needs a current claude CLI)"},
    ],
    "codex": [
        {"id": "gpt-5.6-sol",   "note": "frontier · the config default"},
        {"id": "gpt-6-astra",   "note": "new (Sep 2026) · pick per conversation"},
        {"id": "gpt-5.6-terra", "note": "balanced everyday"},
        {"id": "gpt-5.6-luna",  "note": "fast, affordable"},
    ],
    "recommended": "claude-opus-5",
}


# Cursor's menu is the account's own (`agent models`), so it is asked live and
# cached for a day; this list is the floor when Cursor is absent or silent.
CURSOR_MODELS_FALLBACK = [
    {"id": "auto",                        "note": "Cursor picks (default)"},
    {"id": "gpt-5.3-codex",               "note": "Codex 5.3"},
    {"id": "composer-2.5",                "note": "Composer 2.5"},
    {"id": "claude-opus-5-thinking-high", "note": "Claude Opus 5 1M Thinking"},
    {"id": "gpt-5.6-sol-high",            "note": "GPT-5.6 Sol 1M High"},
]


def _find_cursor_agent():
    import shutil
    for name in ("agent", "cursor-agent"):
        p = shutil.which(name)
        if p:
            return p
        for d in (os.path.expanduser("~/.local/bin"), "/opt/homebrew/bin", "/usr/local/bin"):
            c = os.path.join(d, name)
            if os.access(c, os.X_OK):
                return c
    return ""


def _cursor_menu_cut(models, cap=80):
    """`agent models` lists every variant (265 on 2026-10-16: -low/-medium/
    -high/-xhigh/-max and a -fast twin of each). A phone menu wants ONE entry
    per family, in Cursor's own order, and ALL the families: the first cut
    (16, first variant seen) showed grok-4.7-low and claude-opus-5-5-low while
    kimi/glm/gemini never made the list — "model list 对不上" (2026-10-16).
    The entry for a family is its plain id when Cursor has one, else the
    usual effort: high, then medium, low, xhigh, max. No -fast twins."""
    order = ["", "-high", "-medium", "-low", "-xhigh", "-max"]
    def base(mid):
        b = re.sub(r"-fast$", "", mid)
        return re.sub(r"-(low|medium|high|xhigh|max)$", "", b)
    by_id = {m.get("id", ""): m for m in models}
    families, seen = [], set()
    for m in models:
        mid = m.get("id", "")
        if not mid or mid.endswith("-fast") or mid == "auto":
            continue
        b = base(mid)
        if b not in seen:
            seen.add(b)
            families.append(b)
    out = []
    for b in families:
        pick = next((by_id[b + suf] for suf in order if (b + suf) in by_id), None)
        if pick is not None:
            out.append(pick)
    auto = by_id.get("auto") or {"id": "auto", "note": "Cursor picks (default)"}
    return [auto] + out[:cap]


def credentials_env():
    """os.environ with ~/.pervio/credentials.env on top — the file pervio-chat
    sources before a turn (CLAUDE_CODE_OAUTH_TOKEN, CURSOR_API_KEY). A Cursor
    API key there lets `agent models` answer when the keychain login is locked
    for an SSH session (a tester's menu fell back to the fixed list, 2026-10-16)."""
    import shlex
    env = dict(os.environ)
    path = os.path.join(os.path.expanduser("~"), ".pervio", "credentials.env")
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                try:
                    parts = shlex.split(v)
                except ValueError:
                    continue
                env[k.strip()] = " ".join(parts)
    except OSError:
        pass
    # The file credential store when the person logged in through it (see
    # pervio-chat's cursor branch): the keychain one is locked for SSH sessions.
    auth = os.path.join(os.path.expanduser("~"), ".cursor", "auth.json")
    try:
        if os.path.getsize(auth) > 0:
            env["AGENT_CLI_CREDENTIAL_STORE"] = "file"
    except OSError:
        pass
    return env


def cursor_models(max_age=86400):
    """[{id, note}] from `agent models` ("id - label" lines), cached in
    ~/.pervio/cache/cursor-models.json; the fallback list when there is no
    Cursor, no login, or no answer within a few seconds."""
    import subprocess, time
    cache = os.path.join(os.path.expanduser("~"), ".pervio", "cache", "cursor-models.v2.json")   # v2: the per-family rule above
    try:
        if time.time() - os.path.getmtime(cache) < max_age:
            with open(cache, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, list) and data:
                return data
    except (OSError, ValueError):
        pass
    agent = _find_cursor_agent()
    if not agent:
        return list(CURSOR_MODELS_FALLBACK)
    try:
        p = subprocess.run([agent, "models"], capture_output=True, text=True, timeout=6,
                           env=credentials_env())
        out = []
        for line in p.stdout.splitlines():
            m = re.match(r"^\s*([A-Za-z0-9][\w.\[\]=,-]*)\s+-\s+(.+?)\s*$", line)
            if m and m.group(1) != "Available":
                out.append({"id": m.group(1), "note": m.group(2)})
        if not out:
            return list(CURSOR_MODELS_FALLBACK)
        out = _cursor_menu_cut(out)
        try:
            os.makedirs(os.path.dirname(cache), mode=0o700, exist_ok=True)
            with open(cache, "w", encoding="utf-8") as f:
                json.dump(out, f)
        except OSError:
            pass
        return out
    except Exception:
        return list(CURSOR_MODELS_FALLBACK)


# Third-party providers people actually point Claude Code / Codex at, with the
# URLs their docs give (checked 2026-10-15): the Anthropic-compatible base for
# Claude Code, the OpenAI-compatible base for Codex, and the /models URL the
# key can be asked for a live model list. Vendors with a China / international
# split carry both regions; the person picks (nothing is assumed from locale).
# Model names drift — the live fetch corrects them; these are the fallbacks.
PROVIDER_PRESETS = [
    {"id": "glm", "label": "智谱 GLM", "docs": "https://docs.bigmodel.cn/cn/guide/develop/claude",
     "note": "Coding Plan 订阅用户的 OpenAI 兼容地址是 …/api/coding/paas/v4。",
     "models": ["glm-5.3", "glm-5.2", "glm-5", "glm-4.7"], "defaultModel": "glm-5.3", "wireApi": "chat",
     "regions": [
         {"id": "cn", "label": "中国区", "claudeUrl": "https://open.bigmodel.cn/api/anthropic",
          "codexUrl": "https://open.bigmodel.cn/api/paas/v4", "modelsUrl": "https://open.bigmodel.cn/api/paas/v4/models"},
         {"id": "intl", "label": "国际版", "claudeUrl": "https://api.z.ai/api/anthropic",
          "codexUrl": "https://api.z.ai/api/paas/v4", "modelsUrl": "https://api.z.ai/api/paas/v4/models"}]},
    {"id": "kimi", "label": "Kimi · 月之暗面", "docs": "https://platform.kimi.com/docs/guide/claude-code-kimi",
     "note": "", "models": ["kimi-k3", "kimi-k2.7-code-highspeed", "kimi-k2.6"], "defaultModel": "kimi-k3", "wireApi": "chat",
     "regions": [
         {"id": "cn", "label": "中国区", "claudeUrl": "https://api.moonshot.cn/anthropic",
          "codexUrl": "https://api.moonshot.cn/v1", "modelsUrl": "https://api.moonshot.cn/v1/models"},
         {"id": "intl", "label": "国际版", "claudeUrl": "https://api.moonshot.ai/anthropic",
          "codexUrl": "https://api.moonshot.ai/v1", "modelsUrl": "https://api.moonshot.ai/v1/models"}]},
    {"id": "minimax", "label": "MiniMax", "docs": "https://platform.minimax.io/docs",
     "note": "", "models": ["MiniMax-M3", "MiniMax-M2.7", "MiniMax-M2.5", "MiniMax-M2"], "defaultModel": "MiniMax-M3", "wireApi": "chat",
     "regions": [
         {"id": "cn", "label": "中国区", "claudeUrl": "https://api.minimaxi.com/anthropic",
          "codexUrl": "https://api.minimaxi.com/v1", "modelsUrl": "https://api.minimaxi.com/v1/models"},
         {"id": "intl", "label": "国际版", "claudeUrl": "https://api.minimax.io/anthropic",
          "codexUrl": "https://api.minimax.io/v1", "modelsUrl": "https://api.minimax.io/v1/models"}]},
    {"id": "deepseek", "label": "DeepSeek", "docs": "https://api-docs.deepseek.com/guides/anthropic_api",
     "note": "", "models": ["deepseek-v4-pro", "deepseek-flash", "deepseek-chat", "deepseek-reasoner"],
     "defaultModel": "deepseek-v4-pro", "wireApi": "chat",
     "regions": [
         {"id": "global", "label": "", "claudeUrl": "https://api.deepseek.com/anthropic",
          "codexUrl": "https://api.deepseek.com/v1", "modelsUrl": "https://api.deepseek.com/v1/models"}]},
    {"id": "qwen", "label": "通义千问 · 百炼", "docs": "https://qwenlm.github.io/blog/qwen3-coder/",
     "note": "钥匙按地区发,中国区的钥匙在国际版不能用。",
     "models": ["qwen3-coder-plus", "qwen3-coder-flash"], "defaultModel": "qwen3-coder-plus", "wireApi": "chat",
     "regions": [
         {"id": "cn", "label": "中国区", "claudeUrl": "https://dashscope.aliyuncs.com/api/v2/apps/claude-code-proxy",
          "codexUrl": "https://dashscope.aliyuncs.com/compatible-mode/v1",
          "modelsUrl": "https://dashscope.aliyuncs.com/compatible-mode/v1/models"},
         {"id": "intl", "label": "国际版", "claudeUrl": "https://dashscope-intl.aliyuncs.com/api/v2/apps/claude-code-proxy",
          "codexUrl": "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
          "modelsUrl": "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/models"}]},
    {"id": "openrouter", "label": "OpenRouter", "docs": "https://openrouter.ai/docs/cookbook/coding-agents/claude-code-integration",
     "note": "Claude Code 只对 Anthropic 一方的模型保证工具调用稳定;别家模型会多重试。",
     "models": ["anthropic/claude-sonnet-4.5", "anthropic/claude-opus-4.1", "deepseek/deepseek-chat", "z-ai/glm-4.6"],
     "defaultModel": "anthropic/claude-sonnet-4.5", "wireApi": "chat",
     "regions": [
         {"id": "global", "label": "", "claudeUrl": "https://openrouter.ai/api",
          "codexUrl": "https://openrouter.ai/api/v1", "modelsUrl": "https://openrouter.ai/api/v1/models"}]},
]


def provider_presets():
    return [dict(p) for p in PROVIDER_PRESETS]


def _codex_config_value(name):
    """A top-level `name = "…"` line of ~/.codex/config.toml, "" when unset."""
    try:
        with open(os.path.join(os.path.expanduser("~"), ".codex", "config.toml"), encoding="utf-8") as f:
            for line in f:
                if line.lstrip().startswith("["):      # a table: top-level keys are over
                    break
                key, sep, val = line.partition("=")
                if sep and key.strip() == name:
                    return val.strip().split("#")[0].strip().strip('"').strip("'")
    except OSError:
        pass
    return ""


def _codex_config_model():
    """The `model = "…"` line of ~/.codex/config.toml, "" when unset."""
    return _codex_config_value("model")


def codex_service_tier():
    """The Mac's own speed setting — `service_tier` in ~/.codex/config.toml
    ("priority" = codex's Fast, "" = standard). The phone's Fast switch starts
    from it; a turn's own --service-tier overrides it (2026-10-19)."""
    return _codex_config_value("service_tier")


CLAUDE_EFFORTS_FALLBACK = ["low", "medium", "high", "xhigh", "max"]


def _find_claude():
    import shutil
    p = shutil.which("claude")
    if p:
        return p
    for d in (os.path.expanduser("~/.local/bin"), "/opt/homebrew/bin", "/usr/local/bin"):
        c = os.path.join(d, "claude")
        if os.access(c, os.X_OK):
            return c
    return ""


def claude_efforts(max_age=86400):
    """Claude Code's effort levels, read from `claude --help` itself (the line
    `--effort <level>  … (low, medium, high, xhigh, max)`) and cached for a day,
    so the phone's picker follows the CLI when Anthropic adds or drops a level
    (2026-10-19). The shipped list is the floor when there is no claude or the
    help text changes shape."""
    import subprocess, time
    cache = os.path.join(os.path.expanduser("~"), ".pervio", "cache", "claude-efforts.json")
    try:
        if time.time() - os.path.getmtime(cache) < max_age:
            with open(cache, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, list) and data:
                return data
    except (OSError, ValueError):
        pass
    claude = _find_claude()
    if not claude:
        return list(CLAUDE_EFFORTS_FALLBACK)
    try:
        p = subprocess.run([claude, "--help"], capture_output=True, text=True, timeout=8)
        m = re.search(r"--effort\s+<level>[\s\S]{0,200}?\(([a-z]+(?:,\s*[a-z]+)+)\)", p.stdout)
        levels = [x.strip() for x in m.group(1).split(",")] if m else []
        levels = [x for x in levels if re.match(r"^[a-z]+$", x)]
    except (OSError, subprocess.SubprocessError):
        levels = []
    if not levels:
        return list(CLAUDE_EFFORTS_FALLBACK)
    try:
        os.makedirs(os.path.dirname(cache), exist_ok=True)
        with open(cache, "w", encoding="utf-8") as f:
            json.dump(levels, f)
    except OSError:
        pass
    return levels


# The Claude menu's families, in the order the phone shows them. Mythos is left
# out: the same model as Fable, available to approved organisations only.
CLAUDE_FAMILIES = ("opus", "fable", "sonnet", "haiku")
CLAUDE_MENU_PER_FAMILY = 3
# One row of the model table Claude Code compiles into its program (2.1.322:
# `{id:"claude-fable-5-2",family:"fable",display_name:"Fable 5.2",…}`).
_CLAUDE_TABLE_ROW = re.compile(rb'\{id:"(claude-[a-z0-9.-]+)",family:"([a-z]+)",display_name:"([^"]+)"')


def _claude_version(mid):
    """claude-fable-5-2 → (5, 2); claude-3-5-haiku → (3, 5); claude-opus-5 →
    (5, 0). A date suffix (20251001) is not a version."""
    nums = [int(x) for x in re.findall(r"(?<![0-9])[0-9]{1,2}(?![0-9])", mid.split("[")[0])]
    return tuple((nums + [0, 0])[:2])


def claude_cli_table(path=None):
    """Claude Code's OWN model table, read from the installed program — the CLI
    compiles it in and has no command that prints it (2026-11-18). Rows
    [{id, family, name}] in the program's order, cached per (path, size,
    mtime) in ~/.pervio/cache/claude-cli-models.json so the 300 MB read
    happens once per CLI version. [] when there is no claude, or the program
    no longer carries the table in this shape — the shipped menu then stands."""
    path = path or _find_claude()
    if not path:
        return []
    try:
        path = os.path.realpath(path)
        st = os.stat(path)
    except OSError:
        return []
    key = {"path": path, "size": st.st_size, "mtime": int(st.st_mtime)}
    cache = os.path.join(os.path.expanduser("~"), ".pervio", "cache", "claude-cli-models.json")
    try:
        with open(cache, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and data.get("key") == key and isinstance(data.get("rows"), list):
            return data["rows"]
    except (OSError, ValueError):
        pass
    rows, seen = [], set()
    try:
        import mmap
        with open(path, "rb") as f:
            with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
                for mt in _CLAUDE_TABLE_ROW.finditer(m):
                    mid = mt.group(1).decode("ascii", "replace")
                    if mid in seen:
                        continue
                    seen.add(mid)
                    rows.append({"id": mid, "family": mt.group(2).decode("ascii", "replace"),
                                 "name": mt.group(3).decode("utf-8", "replace")})
    except (OSError, ValueError):
        return []
    try:
        os.makedirs(os.path.dirname(cache), exist_ok=True)
        with open(cache, "w", encoding="utf-8") as f:
            json.dump({"key": key, "rows": rows}, f)
    except OSError:
        pass
    return rows


def claude_menu_from_table(table):
    """The quick-pick from the CLI's table: for each family its newest few
    versions, newest first — 5.2 AND 5.1 both there, to pin either — then the
    family aliases with what they resolve to today. [] for an empty table."""
    by_family = {}
    for r in table:
        if isinstance(r, dict) and r.get("family") in CLAUDE_FAMILIES and r.get("id"):
            by_family.setdefault(r["family"], []).append(r)
    rows, newest = [], {}
    for fam in CLAUDE_FAMILIES:
        fam_rows = sorted(by_family.get(fam, []), key=lambda r: _claude_version(r["id"]), reverse=True)
        for i, r in enumerate(fam_rows[:CLAUDE_MENU_PER_FAMILY]):
            name = str(r.get("name") or r["id"])
            note = name
            if i == 0:
                note += " · newest " + fam
                newest[fam] = name
            if r["id"] == CHAT_MODELS["recommended"]:
                note += " · recommended"
            rows.append({"id": r["id"], "note": note})
    for fam in CLAUDE_FAMILIES:
        if fam in newest:
            rows.append({"id": fam, "note": "alias: always the newest %s (%s today)" % (fam, newest[fam])})
    return rows


def claude_models():
    """The Claude quick-pick: the installed CLI's own model table when it can be
    read — every version listed, newest first, so a new model is on the phone
    as soon as the Mac's Claude Code knows it, no app release (the shipped
    list is hand-written and stood at Fable 5.1 while 5.2 was out, 2026-11-18)
    — else the shipped list; plus whatever extra models Claude Code itself has
    learned the account can use (~/.claude.json `additionalModelOptionsCache`:
    value / label / description), after those rows, deduped."""
    rows = claude_menu_from_table(claude_cli_table()) or [dict(m) for m in CHAT_MODELS["claude"]]
    try:
        with open(os.path.join(os.path.expanduser("~"), ".claude.json"), encoding="utf-8") as f:
            extra = (json.load(f) or {}).get("additionalModelOptionsCache") or []
    except (OSError, ValueError, AttributeError):
        extra = []
    seen = {r["id"] for r in rows}
    for m in extra:
        if not isinstance(m, dict) or not m.get("value") or m["value"] in seen:
            continue
        note = " · ".join(x for x in (m.get("label"), m.get("description")) if x)
        rows.append({"id": str(m["value"]), "note": note or "from Claude Code's own list"})
        seen.add(m["value"])
    return rows


def codex_models():
    """Codex's OWN model table — ~/.codex/models_cache.json, which codex refreshes
    from OpenAI by itself — as the chat menu: every model it lists for picking,
    with the reasoning levels it supports and its default, so the phone offers
    exactly what the person's codex has, in codex's own order (the static table
    listed four models and six levels, half of them wrong for today's models —
    the person, 2026-10-18). The static table is the floor when the cache is
    absent or unreadable (codex never run, or an older codex)."""
    try:
        with open(os.path.join(os.path.expanduser("~"), ".codex", "models_cache.json"), encoding="utf-8") as f:
            cache = json.load(f)
    except (OSError, ValueError):
        return [dict(m) for m in CHAT_MODELS["codex"]]
    default = _codex_config_model()
    rows = []
    for m in (cache.get("models") if isinstance(cache, dict) else None) or []:
        if not isinstance(m, dict) or m.get("visibility", "list") != "list" or not m.get("slug"):
            continue
        levels = [e.get("effort") for e in (m.get("supported_reasoning_levels") or [])
                  if isinstance(e, dict) and e.get("effort")]
        note = m.get("display_name") or m["slug"]
        if m["slug"] == default:
            note += " · the config default"
        prio = m.get("priority")
        row = {"id": m["slug"], "note": note, "efforts": levels,
               "defaultEffort": m.get("default_reasoning_level") or ""}
        # The model's faster service tier, as codex's table describes it
        # ("Fast · 2x speed, increased usage"); absent when the model has none.
        tiers = [t for t in (m.get("service_tiers") or []) if isinstance(t, dict) and t.get("id")]
        if tiers:
            row["fast"] = {"id": str(tiers[0]["id"]), "name": str(tiers[0].get("name") or "Fast"),
                           "description": str(tiers[0].get("description") or "")}
        rows.append((prio if isinstance(prio, (int, float)) else float("inf"), len(rows), row))
    rows.sort(key=lambda r: (r[0], r[1]))
    return [r[2] for r in rows] or [dict(m) for m in CHAT_MODELS["codex"]]


def models_menu():
    """What `pervio-orchestrate models` prints: tiers + chat menu, one JSON."""
    chat = dict(CHAT_MODELS)
    chat["claude"] = claude_models()
    chat["claudeEfforts"] = claude_efforts()
    chat["codex"] = codex_models()
    chat["codexServiceTier"] = codex_service_tier()
    chat["codexDefaultModel"] = _codex_config_model()
    chat["cursor"] = cursor_models()
    return {"v": 1, "tiers": dict(MODEL_TIERS), "chat": chat}


def resolve_model(name):
    """Tier name -> today's model id; anything else (raw ids, None) verbatim."""
    return MODEL_TIERS.get(name or "", name)


class DispatchError(Exception):
    """A gate/setup failure. Carries a machine code so the CLI can print it and the
    fan-out collector can record it — instead of exiting the process."""
    def __init__(self, code, detail=""):
        self.code = code
        self.detail = detail
        super().__init__("%s: %s" % (code, detail))


def push_lang():
    """The PHONE's language for server-authored push copy — "zh" or "en".

    The app writes ~/.pervio/push/lang beside its APNs token (same SSH round
    trip) whenever the token or the Settings language changes, so every sender
    of lock-screen copy (pervio-run, pervio-orchestrate, pervio-approve) can speak
    the language the phone is set to. Absent file, unreadable file, or contents
    that aren't an English tag ⇒ "zh", the shipped default — a missing
    preference must not change a single byte of what was always sent. Read at
    CALL time (expanduser, no module constant): tests fence $HOME around a
    loaded module, and a user can flip Settings between two pushes of the same
    workflow.
    """
    try:
        with open(os.path.join(os.path.expanduser("~"), ".pervio", "push", "lang"),
                  encoding="utf-8") as f:
            return "en" if f.read().strip().lower().startswith("en") else "zh"
    except OSError:
        return "zh"


# ---- tier power: 0=read-only, 1=write, 2=full (never granted to a child) ----

def tier_power(backend, tier):
    if backend == "codex":
        return {"read-only": 0, "workspace-write": 1, "danger-full-access": 2}.get(tier, 0)
    return {"plan": 0, "default": 0, "acceptEdits": 1, "dontAsk": 1, "auto": 1,
            "bypassPermissions": 2}.get(tier, 0)


def power_to_tier(backend, p):
    if backend == "codex":
        return "workspace-write" if p >= 1 else "read-only"
    return "acceptEdits" if p >= 1 else "plan"


def clamp_tier(backend, requested, parent_backend, parent_tier):
    """Child tier = min(requested, parent write-power), never above write; bypass /
    danger-full-access are hard-refused. Raises DispatchError('tier_refused')."""
    if requested in BANNED:
        raise DispatchError("tier_refused", "%s is never granted to a child" % requested)
    eff = min(tier_power(backend, requested), tier_power(parent_backend, parent_tier), 1)
    return power_to_tier(backend, eff)


def git(cwd, *args):
    """git with hooks disabled (a fresh worktree lacks node_modules husky needs)."""
    try:
        p = subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-C", cwd] + list(args),
                           stdin=subprocess.DEVNULL, capture_output=True, text=True)
        return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()
    except OSError as e:
        return 127, "", str(e)


def child_result(path, backend):
    """Text + USD cost from a child's stream-json. Claude carries total_cost_usd on
    the result event; codex carries none."""
    text, cost, is_err = "", 0.0, False
    try:
        with open(path, "r", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                t = o.get("type")
                if backend == "codex":
                    if t == "item.completed" and (o.get("item") or {}).get("type") == "agent_message":
                        text = (o["item"].get("text") or text)
                    elif t in ("turn.failed", "error"):
                        is_err = True
                else:
                    if t == "result":
                        text = o.get("result") or text
                        cost = float(o.get("total_cost_usd") or 0)
                        is_err = bool(o.get("is_error"))
    except OSError:
        pass
    return text, cost, is_err


def run_child(prompt_b64, backend, tier, repo_top, child_dir, branch, depth,
              timeout, chat_bin, model=None, effort=None, allow_tools=None,
              allow_network=False, extra_env=None, on_spawn=None, on_reap=None):
    """Run ONE child agent turn in an EPHEMERAL git worktree off HEAD; return
    (ok, text, costUSD, error). The worktree — and the child's file writes — are
    discarded, so only text + cost come back and a child can't touch the real repo.
    With repo_top=None (the dir isn't a git repo) the child runs in a throwaway
    SCRATCH dir instead — same containment (writes discarded, the real dir is
    never its cwd), there's just no repo snapshot to read: the per-item prompt
    text is the data. `tier` must already be clamped by the caller. Raises
    DispatchError on a setup failure (bad repo / worktree add). NEVER calls sys.exit.
    on_spawn/on_reap(pid): optional hooks a caller uses to register the child's
    process-group leader while it's alive (so an external delete can reap it — the
    child runs in its OWN session, see below)."""
    os.makedirs(child_dir, mode=0o700, exist_ok=True)
    wt = os.path.join(child_dir, "wt")
    out_path = os.path.join(child_dir, "out.jsonl")
    if repo_top is None:
        os.makedirs(wt, mode=0o700, exist_ok=True)
    else:
        rc, head, _ = git(repo_top, "rev-parse", "HEAD")
        if rc != 0 or not head:
            raise DispatchError("not_a_repo", "repo has no HEAD")
        add = ["worktree", "add", wt, "-b", branch, head]
        rc, _, e = git(repo_top, *add)
        if rc != 0:                   # stale registration from a crash: prune + retry once
            git(repo_top, "worktree", "prune")
            rc, _, e = git(repo_top, *add)
        if rc != 0:
            raise DispatchError("start_failed", "worktree: %s" % (e or "git error"))
    try:
        cmd = [chat_bin, "--text", "--backend", backend, "--dir", wt, "--prompt-b64", prompt_b64]
        if backend == "codex":
            cmd += ["--sandbox", tier]
        else:
            allow = allow_tools or DEFAULT_TOOLS
            if allow_network and "WebFetch" not in allow:
                allow = allow + ",WebFetch"
            cmd += ["--perm", tier, "--allow", allow]
            if tier == "plan":
                # A headless plan child has nobody to answer ExitPlanMode's
                # "approve?" — the call errors and the turn dies with an empty
                # final message (2026-08-20 autopsy: the child had WRITTEN its
                # JSON, then knocked on an unattended door). Strip the tool
                # from the model's view outright; begging in the prompt would
                # only lower the odds. The App's interactive plan flow doesn't
                # come through run_child, so its approval sheet is untouched.
                cmd += ["--disallow", "ExitPlanMode"]
        if model:
            cmd += ["--model", model]
        if effort:
            cmd += ["--effort", effort]
        # Child env: it BECOMES the parent for any grandchild (depth+1, tier=eff).
        cenv = dict(os.environ)
        if extra_env:
            cenv.update(extra_env)
        cenv["PERVIO_DISPATCH_DEPTH"] = str(depth + 1)
        cenv["PERVIO_PARENT_TIER"] = tier
        cenv["PERVIO_PARENT_BACKEND"] = backend
        # stdout -> a regular FILE (not a pipe): pervio-hb injects heartbeats only when
        # its stdout isn't a regular file, so a file keeps the child stream clean.
        # Own session (start_new_session) so a timeout can killpg the child's WHOLE
        # subtree — its Bash-tool children, MCP servers — not just pervio-chat, which
        # subprocess.run's timeout would kill alone, leaking the rest.
        # ONE structural retry (2026-08-20): a child that ends OK but with an
        # EMPTY final message produced nothing usable — never a legitimate
        # outcome for a dispatch/fan-out child (even "nothing found" is words,
        # e.g. NO_CANDIDATES). One more attempt; the first stream is kept as
        # out.jsonl.empty1 for the autopsy. Errors and timeouts do NOT retry —
        # they mean something, and retrying them hides it.
        text, cost, is_err, total_cost = "", 0.0, False, 0.0
        for attempt in (1, 2):
            timed_out = False
            with open(out_path, "wb") as of:
                p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=of,
                                     stderr=subprocess.DEVNULL, env=cenv,
                                     start_new_session=True)
                if on_spawn:
                    on_spawn(p.pid)
                try:
                    p.communicate(timeout=timeout)
                except subprocess.TimeoutExpired:
                    timed_out = True
                    try:
                        os.killpg(os.getpgid(p.pid), signal.SIGKILL)
                    except OSError:
                        p.kill()
                    try:
                        p.communicate(timeout=5)
                    except (subprocess.SubprocessError, OSError):
                        pass
                finally:
                    if on_reap:
                        on_reap(p.pid)
            text, cost, is_err = child_result(out_path, backend)
            total_cost += cost
            if timed_out or is_err or (text or "").strip():
                break
            if attempt == 1:
                try:                       # 留尸检:第一份空流改名存档
                    os.replace(out_path, out_path + ".empty1")
                except OSError:
                    pass
        if timed_out:
            return (False, text, total_cost, "timeout")
        return ((not is_err), text, total_cost, ("child_error" if is_err else None))
    finally:
        if repo_top is None:
            shutil.rmtree(wt, ignore_errors=True)
        else:
            git(repo_top, "worktree", "remove", "--force", wt)
