#!/usr/bin/env bash
# Add one independent AWG 3.1 client to the server created by this project.
set -Eeuo pipefail
umask 077

if [[ ${EUID} -ne 0 ]]; then echo 'Run as root.' >&2; exit 1; fi
name=${1:-}
endpoint=${2:-}
if [[ ! $name =~ ^[a-zA-Z0-9_-]{1,15}$ || ! $endpoint =~ ^[a-zA-Z0-9.-]+$ ]]; then
  echo "Usage: bash $0 CLIENT_NAME PUBLIC_IP_OR_HOSTNAME" >&2; exit 1
fi
server=/etc/amnezia/amneziawg/awg0.conf
clients_dir=/root/awg-clients
client_file=$clients_dir/$name.conf
if [[ ! -f $server ]]; then echo 'Server configuration is missing.' >&2; exit 1; fi
systemctl is-active --quiet awg-quick@awg0 || { echo 'awg0 is not active.' >&2; exit 1; }
command -v flock >/dev/null
exec 9>/run/lock/awg-add-client.lock
flock -x 9
install -d -m 700 "$clients_dir"
if [[ -e $client_file ]]; then echo "Client already exists: $name" >&2; exit 1; fi
if grep -Fxq "# Client: $name" "$server"; then echo "Peer name already exists: $name" >&2; exit 1; fi

address=$(awk -F= '/^Address[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$server")
port=$(awk -F= '/^ListenPort[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$server")
if [[ $address != 10.77.77.1/24 || ! $port =~ ^[0-9]+$ ]]; then
  echo 'Unexpected server subnet or listen port.' >&2; exit 1
fi
obfuscation=$(awk '
  /^\[Interface\]$/ { inside=1; next }
  /^\[/ { inside=0 }
  inside && /^(Jc|Jmin|Jmax|S[1-4]|H[1-4]|I[1-5]|HeaderProtectionKey|ContentPaddingAddition|RandomTrailers|DisableCookies|RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts)[[:space:]]*=/ { print }
' "$server")
if ! grep -q '^HeaderProtectionKey[[:space:]]*=' <<< "$obfuscation"; then
  echo 'Server is not configured for AWG 3.1 header protection.' >&2; exit 1
fi
client_ip=$(python3 - "$server" <<'PY'
import pathlib
import re
import sys

config = pathlib.Path(sys.argv[1]).read_text()
used = {int(host) for host in re.findall(r'10\.77\.77\.(\d+)/32', config)}
for host in range(2, 255):
    if host not in used:
        print(f'10.77.77.{host}')
        break
else:
    raise SystemExit('No free client IP addresses')
PY
)

client_private=$(awg genkey)
client_public=$(printf '%s' "$client_private" | awg pubkey)
server_public=$(awg show awg0 public-key)
psk=$(awg genpsk)
psk_file=$(mktemp)
server_backup=$(mktemp)
client_tmp=$(mktemp "$clients_dir/.$name.XXXXXX")
server_modified=0
cleanup() {
  rc=$?
  trap - EXIT
  if (( rc != 0 )); then
    if (( server_modified )); then
      cp -p "$server_backup" "$server"
      awg set awg0 peer "$client_public" remove || true
    fi
    rm -f "$client_tmp" "$client_file"
  fi
  rm -f "$psk_file" "$server_backup"
  exit "$rc"
}
trap cleanup EXIT
cp -p "$server" "$server_backup"
printf '%s\n' "$psk" > "$psk_file"
cat > "$client_tmp" <<CONFIG
[Interface]
PrivateKey = $client_private
Address = $client_ip/32
DNS = 1.1.1.1
$obfuscation

[Peer]
PublicKey = $server_public
PresharedKey = $psk
Endpoint = $endpoint:$port
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CONFIG
server_modified=1
cat >> "$server" <<CONFIG

# Client: $name
[Peer]
PublicKey = $client_public
PresharedKey = $psk
AllowedIPs = $client_ip/32
CONFIG
awg-quick strip "$server" >/dev/null
awg set awg0 peer "$client_public" preshared-key "$psk_file" allowed-ips "$client_ip/32"
mv "$client_tmp" "$client_file"
chmod 600 "$client_file" "$server"
echo "Added $name at $client_ip. Securely copy $client_file to the client."
