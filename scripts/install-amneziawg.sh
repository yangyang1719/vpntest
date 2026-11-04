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
apt-get update
apt-get install -y software-properties-common python3-launchpadlib gnupg2 "linux-headers-$(uname -r)" iptables
add-apt-repository -y ppa:amnezia/ppa
apt-get update
apt-get install -y amneziawg
command -v awg >/dev/null
command -v awg-quick >/dev/null
install -d -m 700 /etc/amnezia/amneziawg
server_private=$(awg genkey)
server_public=$(printf '%s' "$server_private" | awg pubkey)
client_private=$(awg genkey)
client_public=$(printf '%s' "$client_private" | awg pubkey)
psk=$(awg genpsk)
# AWG 1.x-compatible fixed headers; matching values are required at both ends.
cat > /etc/amnezia/amneziawg/awg0.conf <<CONFIG
[Interface]
Address = 10.77.77.1/24
ListenPort = $port
PrivateKey = $server_private
Jc = 4
Jmin = 40
Jmax = 70
S1 = 0
S2 = 0
H1 = 123456789
H2 = 987654321
H3 = 111111111
H4 = 222222222
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
S1 = 0
S2 = 0
H1 = 123456789
H2 = 987654321
H3 = 111111111
H4 = 222222222

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
