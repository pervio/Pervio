#!/usr/bin/env bash
# The pictures the website shows that are cut FROM something else — nothing
# here is drawn. Five jobs, each on its own word:
#
#     bash scripts/site-crops.sh [FULLDIR]     the close-ups of the five stages, cut from the
#                                              full-size screens scripts/site-shots.sh photographs
#                                              (default: ios/DerivedData/site-shots), the hero's
#                                              screen in AVIF, and the Dynamic Island on its own
#     bash scripts/site-crops.sh photo FILE    the hero and closing photographs, from the 3840 px
#                                              wide copy of the Commons file named in
#                                              THIRD_PARTY_NOTICES.md
#     bash scripts/site-crops.sh readme        the README's pictures, from scripts/readme-hero.html
#     bash scripts/site-crops.sh badges        the README's badges: three facts, and one per agent
#                                              with the app's own mark (readme does these too)
#     bash scripts/site-crops.sh notif         the two notification banners: the real payloads
#                                              (the words pervio-run and pervio-approve send),
#                                              pushed to a booted simulator with the app on it and
#                                              photographed as iOS itself draws them
#
# The cut lines below are rows of the 1320 × 2868 screens as the staged
# conversation lays out today, one set per language (English wraps longer).
# Change the staging in SiteShotsTests and they want another look.
#
# web/en.html carries each picture's height: run scripts/make-web-en.py after,
# and if a crop's height changed, update it there and in web/index.html.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB="$ROOT/web/assets"
SRGB="/System/Library/ColorSync/Profiles/sRGB Profile.icc"
command -v sips >/dev/null || { echo "needs macOS (sips)" >&2; exit 1; }

avif() { sips -m "$SRGB" -s format avif -s formatOptions "$3" "$1" --out "$2" >/dev/null; }
size() { sips -g pixelWidth -g pixelHeight "$1" | awk '/pixel/{printf "%s%s", s, $2; s="x"}'; }

crops() {
  local full="${1:-$ROOT/ios/DerivedData/site-shots}" tmp
  [ -f "$full/chat-zh.png" ] || { echo "no full-size screens in $full — run scripts/site-shots.sh first" >&2; exit 1; }
  tmp="$(mktemp -d)"; trap "rm -rf '$tmp'" EXIT
  # name  source  first row  row after the last
  while read -r name src top bottom; do
    [ -n "$name" ] || continue
    sips -c $((bottom - top)) 1320 --cropOffset "$top" 1 "$full/$src.png" --out "$tmp/$name.png" >/dev/null
    avif "$tmp/$name.png" "$WEB/shots/$name.avif" 62
    sips -m "$SRGB" --resampleWidth 1100 -s format jpeg -s formatOptions 80 "$tmp/$name.png" --out "$WEB/shots/$name.jpg" >/dev/null
    echo "  $name  $(size "$WEB/shots/$name.avif")"
  done <<'CUTS'
step-ask-zh      chat-zh      352  1664
step-ask-en      chat-en      352  1892
step-run-zh      running-zh   1240 2772
step-run-en      running-en   1100 2772
step-approve-zh  approval-zh  1300 2868
step-approve-en  approval-en  1300 2868
step-duet-zh     duet-zh      1024 2772
step-duet-en     duet-en      1090 2772
step-workflow-zh workflow-zh  330  1974
step-workflow-en workflow-en  330  1974
CUTS
  for l in zh en; do
    avif "$WEB/shots/chat-$l.png" "$WEB/shots/chat-$l.avif" 62
    # the island's own shape inside its 784 × 300 render
    sips -m "$SRGB" -c 230 720 --cropOffset 32 32 "$WEB/snap-island-expanded-$l.png" --out "$WEB/shots/island-$l.png" >/dev/null
  done
  echo "close-ups, hero screen and island written to $WEB/shots"
}

photo() {
  local src="${1:?usage: site-crops.sh photo FILE (the 3840 px wide Commons copy)}" tmp
  [ "$(size "$src")" = "3840x2160" ] || { echo "expected a 3840x2160 picture, got $(size "$src")" >&2; exit 1; }
  tmp="$(mktemp -d)"; trap "rm -rf '$tmp'" EXIT
  mkdir -p "$WEB/photo"
  sips -m "$SRGB" -s format png "$src" --out "$tmp/hero.png" >/dev/null
  avif "$tmp/hero.png" "$WEB/photo/mattole-hero.avif" 44
  sips -m "$SRGB" -z 1620 2880 -s format jpeg -s formatOptions 68 "$src" --out "$WEB/photo/mattole-hero.jpg" >/dev/null
  # phones: the middle of the frame, upright
  sips -m "$SRGB" -s format png -c 2160 1440 --cropOffset 1 1380 "$src" --out "$tmp/tall.png" >/dev/null
  sips -z 1620 1080 "$tmp/tall.png" --out "$tmp/tall.png" >/dev/null
  avif "$tmp/tall.png" "$WEB/photo/mattole-hero-tall.avif" 52
  sips -s format jpeg -s formatOptions 68 "$tmp/tall.png" --out "$WEB/photo/mattole-hero-tall.jpg" >/dev/null
  # the close: the end of the fog bank and the horizon
  sips -m "$SRGB" -s format png -c 900 2340 --cropOffset 1000 1499 "$src" --out "$tmp/close.png" >/dev/null
  avif "$tmp/close.png" "$WEB/photo/mattole-close.avif" 50
  sips -s format jpeg -s formatOptions 66 "$tmp/close.png" --out "$WEB/photo/mattole-close.jpg" >/dev/null
  echo "photographs written to $WEB/photo"
}

notif() {
  local udid tmp before port
  udid="${PERVIO_SHOTS_UDID:-$(xcrun simctl list devices booted | sed -n 's/.*iPhone 16 Pro Max[^(]*(\([0-9A-F-]\{36\}\)).*/\1/p' | head -1)}"
  [ -n "$udid" ] || { echo "no booted iPhone 16 Pro Max simulator — boot one, or set PERVIO_SHOTS_UDID" >&2; exit 1; }
  xcrun simctl get_app_container "$udid" app.pervio >/dev/null 2>&1 || { echo "Pervio is not installed on that simulator (and must have been allowed to notify)" >&2; exit 1; }
  tmp="$(mktemp -d)"; before="$(xcrun simctl ui "$udid" appearance)"
  # A plain page the colour of the site's light surface, so the banner's glass
  # is photographed over what it will sit on; served on a free port, briefly.
  mkdir -p "$tmp/www"
  printf '<!doctype html><meta name="viewport" content="width=device-width"><meta name="theme-color" content="#f3efea"><title> </title><body style="margin:0;background:#f3efea;height:300vh"></body>' > "$tmp/www/index.html"
  python3 -I - "$tmp/www" "$tmp/port" <<'PY' &
import http.server, socketserver, sys, os, time
os.chdir(sys.argv[1])
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
with socketserver.TCPServer(("127.0.0.1", 0), H) as s:
    open(sys.argv[2], "w").write(str(s.server_address[1])); s.timeout = 1
    end = time.time() + 90
    while time.time() < end: s.handle_request()
PY
  local server=$!
  disown "$server" 2>/dev/null || true          # its end is ours to arrange, not the shell's to announce
  # Whatever happens next, the simulator goes back to how it was found.
  trap "kill $server 2>/dev/null || true; xcrun simctl terminate '$udid' com.apple.mobilesafari >/dev/null 2>&1 || true; xcrun simctl ui '$udid' appearance '$before' >/dev/null 2>&1 || true; rm -rf '$tmp'" EXIT
  for _ in $(seq 50); do [ -s "$tmp/port" ] && break; sleep 0.1; done
  port="$(cat "$tmp/port")"
  xcrun simctl terminate "$udid" app.pervio >/dev/null 2>&1 || true     # a banner is not shown over its own app
  xcrun simctl ui "$udid" appearance light
  xcrun simctl openurl "$udid" "http://127.0.0.1:$port/"
  sleep 6
  # The words are the shipped ones: pervio-run's _push_text and pervio-approve's
  # _approve_copy. No sound key: nothing rings on this Mac.
  while IFS='|' read -r name title body; do
    [ -n "$name" ] || continue
    python3 -I -c 'import json,sys; json.dump({"aps":{"alert":{"title":sys.argv[1],"body":sys.argv[2]},"thread-id":"pervio-site-"+sys.argv[3]}}, open(sys.argv[4],"w"), ensure_ascii=False)' "$title" "$body" "$name" "$tmp/$name.json"
    xcrun simctl push "$udid" app.pervio "$tmp/$name.json" >/dev/null
    sleep 2.2
    xcrun simctl io "$udid" screenshot --type=png "$tmp/$name.png" >/dev/null 2>&1
    # the banner itself: 1277 × 202 at (22, 174) on a 1320 px wide screen
    sips -m "$SRGB" -c 202 1277 --cropOffset 174 22 "$tmp/$name.png" --out "$WEB/shots/$name.png" >/dev/null
    echo "  $name  $(size "$WEB/shots/$name.png")"
    sleep 7                                     # let it leave before the next arrives
  done <<'WORDS'
notif-done-zh|shop-api · 任务完成|合到 release 分支，再跑一遍全量测试
notif-approve-zh|Claude 在等你批准|跑命令
notif-done-en|shop-api · task finished|Merge it into release and run the full test suite
notif-approve-en|Claude is waiting for your approval|run a command
WORDS
  echo "banners written to $WEB/shots — look at them: a banner that did not show leaves a plain strip"
}

readme() {
  # The README's pictures (scripts/readme-hero.html composes them from the
  # site's own captures), photographed by headless Chrome at twice the size and
  # brought down to what GitHub shows on a dense screen.
  local chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" tmp out="$ROOT/docs/img/readme"
  [ -x "$chrome" ] || { echo "needs Google Chrome (headless) to photograph the composition" >&2; exit 1; }
  tmp="$(mktemp -d)"; trap "rm -rf '$tmp'" EXIT
  mkdir -p "$out"
  # scene  height  width of the finished picture
  while read -r scene h w; do
    [ -n "$scene" ] || continue
    for l in en zh; do
      # A headless window is 87 px taller than the page it shows.
      "$chrome" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="$tmp/profile" \
        --window-size=1600,$((h + 87)) --force-device-scale-factor=2 --virtual-time-budget=6000 \
        --allow-file-access-from-files --screenshot="$tmp/$scene-$l.png" \
        "file://$ROOT/scripts/readme-hero.html?scene=$scene&lang=$l" >/dev/null 2>&1
      sips -c $((h * 2)) 3200 --cropOffset 1 1 "$tmp/$scene-$l.png" --out "$tmp/$scene-$l.png" >/dev/null
      sips -m "$SRGB" --resampleWidth "$w" -s format jpeg -s formatOptions 84 "$tmp/$scene-$l.png" --out "$out/$scene-$l.jpg" >/dev/null 2>&1
      echo "  $scene-$l.jpg  $(size "$out/$scene-$l.jpg")  $(( $(stat -f %z "$out/$scene-$l.jpg") / 1024 )) KB"
    done
  done <<'SCENES'
hero 1000 2000
away 520  2000
how  560  2000
SCENES
  # The app icon with iOS's corners, on a transparent ground (one file, no language).
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="$tmp/profile" \
    --window-size=500,$((256 + 87)) --force-device-scale-factor=2 --virtual-time-budget=4000 \
    --default-background-color=00000000 --allow-file-access-from-files --screenshot="$tmp/icon.png" \
    "file://$ROOT/scripts/readme-hero.html?scene=icon" >/dev/null 2>&1
  sips -c 512 512 --cropOffset 1 1 "$tmp/icon.png" --out "$out/icon.png" >/dev/null 2>&1
  sips --resampleWidth 256 "$out/icon.png" >/dev/null 2>&1
  echo "  icon.png  $(size "$out/icon.png")  $(( $(stat -f %z "$out/icon.png") / 1024 )) KB"
  badges
  echo "README pictures written to $out"
}

badges() {
  # The README's two rows of badges, in the shape and type of a shields.io
  # flat-square badge and the site's colours. The first row is three facts
  # (licence, system, where the beta is), each a dark label and a coloured
  # value. The second is one badge per agent the app drives: the mark the app
  # itself shows for it (ios/Sources/Assets.xcassets/<name>.imageset) beside
  # its name, on the site's bone surface.
  # They are files so that GitHub serves them itself: a badge that lives on a
  # badge service reaches the page through GitHub's image proxy, and on the day
  # these were made the proxy could not fetch a single new one.
  # A new badge is one row in its table. The numbers are the width of each
  # piece of text in 11 px Verdana, in tenths of a pixel.
  local out="$ROOT/docs/img/readme"
  mkdir -p "$out"
  python3 - "$ROOT/ios/Sources/Assets.xcassets" "$out" <<'PY'
import io, re, sys
assets, out = sys.argv[1], sys.argv[2]
INK, BONE = "#151820", "#F3EFEA"
PERIWINKLE, APRICOT = "#A0B0F4", "#F4BA87"
FONT = 'font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="110" text-rendering="geometricPrecision"'
FACTS = [("license", 370, "MIT", 210, PERIWINKLE, "license"), ("iOS", 190, "17+", 230, PERIWINKLE, "ios"),
         ("TestFlight", 530, "public beta", 610, APRICOT, "testflight")]
for label, lw, value, vw, ground, slug in FACTS:
    a, b = lw // 10 + 10, vw // 10 + 10
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="20" role="img" aria-label="%s: %s"><title>%s: %s</title>'
           '<g shape-rendering="crispEdges"><rect width="%d" height="20" fill="%s"/><rect x="%d" width="%d" height="20" fill="%s"/></g>'
           '<g text-anchor="middle" %s>'
           '<text x="%d" y="140" textLength="%d" transform="scale(.1)" fill="#fff">%s</text>'
           '<text x="%d" y="140" textLength="%d" transform="scale(.1)" fill="#333">%s</text></g></svg>\n'
           % (a + b, label, value, label, value, a, INK, a, b, ground, FONT,
              (a + 2) * 5, lw, label, a * 10 + b * 5 - 10, vw, value))
    io.open("%s/badge-%s.svg" % (out, slug), "w", encoding="utf-8").write(svg)
    print("  badge-%s.svg  %d x 20  %d bytes" % (slug, a + b, len(svg.encode("utf-8"))))
AGENTS = [("Claude Code", 690, "claude-code"), ("Codex", 350, "codex"), ("Cursor", 370, "cursor")]
for name, tw, mark in AGENTS:
    src = io.open("%s/%s.imageset/%s.svg" % (assets, mark, mark), encoding="utf-8").read()
    root = re.search(r"<svg\b[^>]*>", src).group(0)
    attr = dict(re.findall(r'([\w-]+)="([^"]*)"', root))
    assert attr.get("viewBox") == "0 0 24 24", mark
    # The marks are white in the app's dark chrome; here they sit on a light
    # ground, so white becomes ink and a mark's own colour stays.
    ink = lambda v: INK if v.upper() in ("#FFFFFF", "#FFF") else v
    g = {}
    if "stroke" in attr:
        g = {"fill": attr.get("fill", "none"), "stroke": ink(attr["stroke"])}
        for k in ("stroke-width", "stroke-linejoin", "stroke-linecap"):
            if k in attr: g[k] = attr[k]
    else:
        g = {"fill": ink(attr.get("fill", "#FFFFFF"))}
        if "fill-rule" in attr: g["fill-rule"] = attr["fill-rule"]
    paths = "".join(re.findall(r"<path\b[^>]*/>|<path\b[^>]*></path>", src))
    assert paths, mark
    w = tw // 10 + 28
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="20" role="img" aria-label="%s"><title>%s</title>'
           '<rect width="%d" height="20" fill="%s" shape-rendering="crispEdges"/>'
           '<g transform="translate(5 3) scale(.58333)" %s>%s</g>'
           '<text x="%d" y="140" textLength="%d" transform="scale(.1)" text-anchor="middle" fill="%s" '
           'font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="110" text-rendering="geometricPrecision">%s</text></svg>\n'
           % (w, name, name, w, BONE, " ".join('%s="%s"' % kv for kv in g.items()), paths, (w + 18) * 5, tw, INK, name))
    dst = "%s/agent-%s.svg" % (out, mark)
    io.open(dst, "w", encoding="utf-8").write(svg)
    print("  agent-%s.svg  %d x 20  %d bytes" % (mark, w, len(svg.encode("utf-8"))))
PY
}

case "${1:-}" in
  photo)  shift; photo "$@" ;;
  notif)  notif ;;
  readme) readme ;;
  badges) badges ;;
  *)      crops "$@" ;;
esac
