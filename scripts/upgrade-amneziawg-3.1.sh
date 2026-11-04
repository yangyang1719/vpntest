#!/usr/bin/env bash
# Upgrade the single-peer configuration created by install-amneziawg.sh.
set -Eeuo pipefail
umask 077

if [[ ${EUID} -ne 0 ]]; then echo 'Run as root.' >&2; exit 1; fi
server=/etc/amnezia/amneziawg/awg0.conf
client=/root/awg-client.conf
if [[ ! -f $server || ! -f $client ]]; then echo 'Expected server/client configuration is missing.' >&2; exit 1; fi
module_version=$(modinfo -F version amneziawg)
tools_version=$(awg --version | awk 'NR==1 {sub(/^v/, "", $2); print $2}')
if ! dpkg --compare-versions "$module_version" ge 3.1 || ! dpkg --compare-versions "$tools_version" ge 3.1; then
  echo "AmneziaWG 3.1 or newer is required (module: $module_version; tools: $tools_version)." >&2
  exit 1
fi
if grep -q '^HeaderProtectionKey = ' "$server" || grep -q '^HeaderProtectionKey = ' "$client"; then
  echo 'Header protection is already configured; refusing to overwrite.' >&2; exit 1
fi

server_backup=${server}.pre-3.1
client_backup=${client}.pre-3.1
if [[ -e $server_backup || -e $client_backup ]]; then echo 'Backup already exists; refusing to overwrite.' >&2; exit 1; fi
cp -p "$server" "$server_backup"
cp -p "$client" "$client_backup"
rollback() {
  cp -p "$server_backup" "$server"
  cp -p "$client_backup" "$client"
  systemctl restart awg-quick@awg0 || true
}
trap rollback ERR

export AWG_HEADER_PROTECTION_KEY
AWG_HEADER_PROTECTION_KEY=$(awg genkey)
python3 - "$server" "$client" <<'PY'
import os
import pathlib
import re
import sys

keys = re.compile(r'^(?:Jc|Jmin|Jmax|S[1-4]|H[1-4]|I[1-5]|HeaderProtectionKey|ContentPaddingAddition|RandomTrailers|DisableCookies|RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts)\s*=')
settings = (
    'Jc = 4\nJmin = 40\nJmax = 70\n'
    'S1 = 16\nS2 = 16\nS3 = 16\nS4 = 16\n'
    'H1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\n'
    f'HeaderProtectionKey = {os.environ["AWG_HEADER_PROTECTION_KEY"]}\n'
    'ContentPaddingAddition = 16-48\nRandomTrailers = on\n'
)
for name in sys.argv[1:]:
    path = pathlib.Path(name)
    lines = path.read_text().splitlines(keepends=True)
    result = []
    inserted = False
    in_interface = False
    for line in lines:
        if line.strip() == '[Interface]':
            in_interface = True
        elif line.startswith('[') and in_interface:
            result.append(settings + '\n')
            inserted = True
            in_interface = False
        if not (in_interface and keys.match(line)):
            result.append(line)
    if in_interface:
        result.append(settings)
        inserted = True
    if not inserted:
        raise SystemExit(f'No interface section: {path}')
    path.write_text(''.join(result))
PY
chmod 600 "$server" "$client"
systemctl restart awg-quick@awg0
systemctl is-active --quiet awg-quick@awg0
trap - ERR
echo 'AWG 3.1 configuration is active. Re-import /root/awg-client.conf on every client.'
