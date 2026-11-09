#!/usr/bin/env bash
# Configure a UDP relay on a remote Ubuntu 22.04 host over SSH.
set -Eeuo pipefail
if (( $# < 2 || $# > 4 )); then
  echo "Usage: $0 [user@]HK_HOST PHILIPPINES_IPV4 [HK_UDP_PORT [PH_UDP_PORT]]" >&2
  echo 'Set SSH_KEY to a private key path if required.' >&2
  exit 1
fi
host=$1; ph_ip=$2; hk_port=${3:-51820}; ph_port=${4:-51820}
if [[ ! $host =~ ^[a-zA-Z0-9_.@-]+$ || ! $ph_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo 'Invalid host or IPv4 address.' >&2; exit 1; fi
IFS=. read -r -a octets <<< "$ph_ip"
for octet in "${octets[@]}"; do (( 10#$octet <= 255 )) || { echo 'Invalid IPv4 address.' >&2; exit 1; }; done
for port in "$hk_port" "$ph_port"; do
  [[ $port =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || { echo 'Invalid UDP port.' >&2; exit 1; }
done
set --
if [[ -n ${SSH_KEY:-} ]]; then set -- -i "$SSH_KEY"; fi
ssh "$@" "$host" "sudo bash -s -- '$ph_ip' '$hk_port' '$ph_port'" <<'REMOTE'
set -Eeuo pipefail
ph_ip=$1; hk_port=$2; ph_port=$3
. /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 22.04 ]] || { echo 'Ubuntu 22.04 required.' >&2; exit 1; }
command -v iptables >/dev/null
command -v ip >/dev/null
iface=$(ip -4 route get "$ph_ip" | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
[[ $iface =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo 'Cannot determine outbound interface.' >&2; exit 1; }
[[ ! -e /etc/systemd/system/awg-udp-relay.service && ! -e /usr/local/sbin/awg-udp-relay ]] || { echo 'Relay already installed; refusing to overwrite.' >&2; exit 1; }
# Keep rules in dedicated chains so starting the service repeatedly is safe.
cat > /usr/local/sbin/awg-udp-relay <<SCRIPT
#!/bin/bash
set -e
sysctl -w net.ipv4.ip_forward=1 >/dev/null
iptables -t nat -N AWG_RELAY_PRE 2>/dev/null || true
iptables -t nat -N AWG_RELAY_POST 2>/dev/null || true
iptables -N AWG_RELAY_FWD 2>/dev/null || true
iptables -t nat -F AWG_RELAY_PRE
iptables -t nat -F AWG_RELAY_POST
iptables -F AWG_RELAY_FWD
iptables -t nat -A AWG_RELAY_PRE -p udp --dport $hk_port -j DNAT --to-destination $ph_ip:$ph_port
iptables -t nat -A AWG_RELAY_POST -o $iface -p udp -d $ph_ip --dport $ph_port -j MASQUERADE
iptables -A AWG_RELAY_FWD -o $iface -p udp -d $ph_ip --dport $ph_port -j ACCEPT
iptables -A AWG_RELAY_FWD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -t nat -C PREROUTING -j AWG_RELAY_PRE 2>/dev/null || iptables -t nat -I PREROUTING -j AWG_RELAY_PRE
iptables -t nat -C POSTROUTING -j AWG_RELAY_POST 2>/dev/null || iptables -t nat -I POSTROUTING -j AWG_RELAY_POST
iptables -C FORWARD -j AWG_RELAY_FWD 2>/dev/null || iptables -I FORWARD -j AWG_RELAY_FWD
SCRIPT
chmod 700 /usr/local/sbin/awg-udp-relay
cat > /etc/systemd/system/awg-udp-relay.service <<'UNIT'
[Unit]
Description=AmneziaWG UDP relay
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/awg-udp-relay
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now awg-udp-relay.service
echo "Relay configured: UDP $hk_port -> $ph_ip:$ph_port via $iface"
echo 'Allow the UDP port in the cloud security group and check existing firewall policies.'
REMOTE
