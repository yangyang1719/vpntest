#!/usr/bin/env bash
# Run on a disposable Ubuntu ECS instance as root. Client configuration is secret.
set -Eeuo pipefail
umask 077

if [[ ${EUID} -ne 0 ]]; then echo 'Run as root.' >&2; exit 1; fi
endpoint=${1:-}
port=${2:-51820}
if [[ ! $endpoint =~ ^[a-zA-Z0-9.-]+$ || ! $port =~ ^[0-9]+$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
  echo "Usage: sudo $0 PUBLIC_IP_OR_HOSTNAME [UDP_PORT]" >&2; exit 1
fi
. /etc/os-release
if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 22.04 ]]; then echo 'This script targets Ubuntu 22.04 only.' >&2; exit 1; fi
if [[ -e /etc/amnezia/amneziawg/awg0.conf || -e /root/awg-client.conf ]]; then
  echo 'Existing configuration found; refusing to overwrite.' >&2; exit 1
fi
iface=$(ip route show default | awk 'NR==1 {print $5}')
if [[ ! $iface =~ ^[a-zA-Z0-9_.-]+$ ]]; then echo 'Cannot determine default interface.' >&2; exit 1; fi
export DEBIAN_FRONTEND=noninteractive

# Some Ubuntu 22.04 cloud images point at an internal mirror that is unreachable
# from another region. apt-get update can return 0 while using stale indexes.
apt_update_checked() {
  local log
  log=$(mktemp)
  if ! apt-get update -o Acquire::Retries=0 -o Acquire::http::Timeout=10 -o Acquire::https::Timeout=10 >"$log" 2>&1 \
    || grep -Eq '(^Err:|Failed to fetch|Some index files failed to download)' "$log"; then
    tail -20 "$log" >&2
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
}

if ! timeout 8 getent ahostsv4 archive.ubuntu.com >/dev/null; then
  echo 'DNS lookup failed; trying temporary public DNS on the default interface.' >&2
  if ! command -v resolvectl >/dev/null || ! resolvectl dns "$iface" 1.1.1.1 8.8.8.8 \
    || ! timeout 8 getent ahostsv4 archive.ubuntu.com >/dev/null; then
    echo 'DNS is still unavailable. Repair the server resolver before installation.' >&2
    exit 1
  fi
fi
if ! apt_update_checked; then
  if [[ ! -f /etc/apt/sources.list ]] || ! grep -q 'mirrors.cloud.aliyuncs.com/ubuntu' /etc/apt/sources.list; then
    echo 'APT update failed; repair the configured software sources before installation.' >&2
    exit 1
  fi
  backup=/etc/apt/sources.list.pre-amneziawg
  if [[ -e $backup ]]; then echo "Backup already exists: $backup" >&2; exit 1; fi
  cp -p /etc/apt/sources.list "$backup"
  sed -i 's@mirrors.cloud.aliyuncs.com/ubuntu@archive.ubuntu.com/ubuntu@g' /etc/apt/sources.list
  echo "Switched unreachable cloud mirror to archive.ubuntu.com; original saved at $backup." >&2
  apt_update_checked || { echo 'APT update still failed after changing the Ubuntu mirror.' >&2; exit 1; }
fi
apt-get install -y software-properties-common python3-launchpadlib gnupg2 "linux-headers-$(uname -r)" iptables
add-apt-repository -y ppa:amnezia/ppa
apt_update_checked
apt-get install -y amneziawg
command -v awg >/dev/null
command -v awg-quick >/dev/null
module_version=$(modinfo -F version amneziawg)
tools_version=$(awg --version | awk 'NR==1 {sub(/^v/, "", $2); print $2}')
if ! dpkg --compare-versions "$module_version" ge 3.1 || ! dpkg --compare-versions "$tools_version" ge 3.1; then
  echo "AmneziaWG 3.1 or newer is required (module: $module_version; tools: $tools_version)." >&2
  exit 1
fi
install -d -m 700 /etc/amnezia/amneziawg
server_private=$(awg genkey)
server_public=$(printf '%s' "$server_private" | awg pubkey)
client_private=$(awg genkey)
client_public=$(printf '%s' "$client_private" | awg pubkey)
psk=$(awg genpsk)
header_protection_key=$(awg genkey)
# AWG 3.1 header protection requires S1-S4 >= 12 and matching values on both ends.
cat > /etc/amnezia/amneziawg/awg0.conf <<CONFIG
[Interface]
Address = 10.77.77.1/24
ListenPort = $port
PrivateKey = $server_private
Jc = 4
Jmin = 40
Jmax = 70
S1 = 16
S2 = 16
S3 = 16
S4 = 16
H1 = 1
H2 = 2
H3 = 3
H4 = 4
HeaderProtectionKey = $header_protection_key
ContentPaddingAddition = 16-48
RandomTrailers = on
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.77.77.0/24 -o $iface -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.77.77.0/24 -o $iface -j MASQUERADE

[Peer]
PublicKey = $client_public
PresharedKey = $psk
AllowedIPs = 10.77.77.2/32
CONFIG
cat > /root/awg-client.conf <<CONFIG
[Interface]
PrivateKey = $client_private
Address = 10.77.77.2/32
DNS = 1.1.1.1
Jc = 4
Jmin = 40
Jmax = 70
S1 = 16
S2 = 16
S3 = 16
S4 = 16
H1 = 1
H2 = 2
H3 = 3
H4 = 4
HeaderProtectionKey = $header_protection_key
ContentPaddingAddition = 16-48
RandomTrailers = on

[Peer]
PublicKey = $server_public
PresharedKey = $psk
Endpoint = $endpoint:$port
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CONFIG
printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/90-amneziawg-forward.conf
sysctl -p /etc/sysctl.d/90-amneziawg-forward.conf >/dev/null
systemctl enable --now awg-quick@awg0
systemctl is-active --quiet awg-quick@awg0
printf 'Server is active. Securely copy /root/awg-client.conf to your client. Open UDP port %s in the ECS security group.\n' "$port"
