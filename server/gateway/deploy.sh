#!/usr/bin/env bash
# Deploy the push gateway to the Lightsail box. Run FROM the Mac:
#   bash server/gateway/deploy.sh ubuntu@<your-relay-host>
# Idempotent: safe to re-run for upgrades (service file + code + restart).
# Caddy sites are kept in /etc/caddy/sites-enabled so this deployment does not
# overwrite unrelated virtual hosts.
set -euo pipefail
HOST="${1:?usage: deploy.sh user@host}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APNS="$HOME/.pervio/apns"

[ -f "$APNS"/AuthKey_*.p8 ] || { echo "no APNs key in $APNS"; exit 1; }

echo "== 传文件"
scp -q "$here/pervio-push-gateway.py" "$here/pervio-push-gateway.service" \
       "$here/Caddyfile" "$APNS"/AuthKey_*.p8 "$APNS/key_id" "$APNS/issuer_id" \
       "$HOST":/tmp/pervio-gw/ 2>/dev/null || {
  ssh "$HOST" 'mkdir -p /tmp/pervio-gw'
  scp -q "$here/pervio-push-gateway.py" "$here/pervio-push-gateway.service" \
         "$here/Caddyfile" "$APNS"/AuthKey_*.p8 "$APNS/key_id" "$APNS/issuer_id" \
         "$HOST":/tmp/pervio-gw/
}

echo "== 服务器就位"
ssh "$HOST" 'sudo bash -s' << 'REMOTE'
set -euo pipefail
id -u pervio-gw >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin pervio-gw
mkdir -p /opt/pervio-gateway /etc/pervio-gateway
install -m 0644 /tmp/pervio-gw/pervio-push-gateway.py /opt/pervio-gateway/
install -m 0640 -g pervio-gw /tmp/pervio-gw/AuthKey_*.p8 /etc/pervio-gateway/
install -m 0640 -g pervio-gw /tmp/pervio-gw/key_id /tmp/pervio-gw/issuer_id /etc/pervio-gateway/
install -m 0644 /tmp/pervio-gw/pervio-push-gateway.service /etc/systemd/system/
command -v caddy >/dev/null || { apt-get update -qq && apt-get install -y -qq caddy; }

caddy_main=/etc/caddy/Caddyfile
caddy_sites=/etc/caddy/sites-enabled
caddy_site="$caddy_sites/push.pervio.dev.caddy"
caddy_stage="$(mktemp -d)"
trap 'rm -rf "$caddy_stage" /tmp/pervio-gw' EXIT
mkdir -p "$caddy_sites"

# Build the prospective main config without touching the live file. The first
# branch migrates the exact legacy config previously installed by this script.
if [ ! -s "$caddy_main" ]; then
  printf 'import /etc/caddy/sites-enabled/*.caddy\n' > "$caddy_stage/Caddyfile"
else
  cp "$caddy_main" "$caddy_stage/Caddyfile"
  if ! grep -Eq '^[[:space:]]*import[[:space:]]+(/etc/caddy/)?sites-enabled/\*\.caddy([[:space:]]|$)' "$caddy_main"; then
    if cmp -s "$caddy_main" /tmp/pervio-gw/Caddyfile; then
      printf 'import /etc/caddy/sites-enabled/*.caddy\n' > "$caddy_stage/Caddyfile"
    elif grep -Eq '^[[:space:]]*push\.pervio\.dev[[:space:]]*\{' "$caddy_main"; then
      echo "refusing to replace an unrecognized push.pervio.dev block in $caddy_main" >&2
      echo "move that block to $caddy_site, then re-run this deployment" >&2
      exit 1
    else
      printf '\nimport /etc/caddy/sites-enabled/*.caddy\n' >> "$caddy_stage/Caddyfile"
    fi
  elif grep -Eq '^[[:space:]]*push\.pervio\.dev[[:space:]]*\{' "$caddy_main"; then
    echo "refusing to add $caddy_site while $caddy_main also defines push.pervio.dev" >&2
    echo "remove or migrate the duplicate block, then re-run this deployment" >&2
    exit 1
  fi
fi

# Keep backups only for validation rollback. The install is idempotent and the
# site fragment is the sole Caddy file owned by this gateway deployment.
[ ! -e "$caddy_main" ] || cp -a "$caddy_main" "$caddy_stage/Caddyfile.backup"
[ ! -e "$caddy_site" ] || cp -a "$caddy_site" "$caddy_stage/site.backup"
install -m 0644 "$caddy_stage/Caddyfile" "$caddy_main"
install -m 0644 /tmp/pervio-gw/Caddyfile "$caddy_site"

if ! caddy validate --config "$caddy_main" --adapter caddyfile; then
  if [ -e "$caddy_stage/Caddyfile.backup" ]; then
    cp -a "$caddy_stage/Caddyfile.backup" "$caddy_main"
  else
    rm -f "$caddy_main"
  fi
  if [ -e "$caddy_stage/site.backup" ]; then
    cp -a "$caddy_stage/site.backup" "$caddy_site"
  else
    rm -f "$caddy_site"
  fi
  echo "Caddy validation failed; restored the previous configuration" >&2
  exit 1
fi

systemctl daemon-reload
systemctl enable --now pervio-push-gateway
systemctl restart pervio-push-gateway
systemctl reload caddy
sleep 2
systemctl is-active pervio-push-gateway caddy
REMOTE

echo "== 健康检查"
sleep 3
curl -s --max-time 15 https://push.pervio.dev/v1/health && echo
