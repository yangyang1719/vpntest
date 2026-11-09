# VPN 测试

这是面向临时 Ubuntu 22.04 云服务器的 AmneziaWG 安装脚本原型。

**当前状态：已在 Ubuntu 22.04.5 测试服务器及 Android 真机上验证 AmneziaWG 3.1 配置、握手、IPv4 流量、DNS 和服务重启恢复；尚未完成整机重启及异常清理验证。** 脚本不会创建或删除阿里云实例、磁盘、安全组或公网 IP。IPv6 没有通过隧道，不能保证隐私保护。请勿将此原型用于需要可靠安全保障的场景。

新安装脚本位于 `scripts/install-amneziawg.sh`，要求 AmneziaWG 内核模块和工具均为 3.1 或更新版本，会安装官方软件包、修改 IPv4 转发及防火墙规则、启动服务并在服务器的 `/root/awg-client.conf` 生成包含私钥的客户端配置。已有旧配置可用 `scripts/upgrade-amneziawg-3.1.sh` 升级：它会保留原密钥、备份两个配置文件、切换 3.1 混淆参数并重启服务；每台客户端都要重新导入新配置。配置和备份必须保密，绝不要提交到 Git 或公开分享。ECS 安全组需要允许所选 UDP 端口入站。实例删除后需另行检查磁盘、公网 IP 等资源是否仍在计费。

该脚本会更改服务器系统配置，并要求 root 权限。使用前请先审阅脚本，在可销毁的测试服务器上验证客户端连接、DNS、重启及异常清理行为。

## 使用方法

仅在可销毁的 Ubuntu 22.04 测试服务器上运行。先在云安全组放行所选 UDP 端口（默认 51820）。安装脚本会检查软件源更新是否真正成功；如果 DNS 解析失败，会尝试临时使用 `1.1.1.1` 和 `8.8.8.8`；如果阿里云内网镜像不可用，会先备份 `/etc/apt/sources.list` 为 `/etc/apt/sources.list.pre-amneziawg`，再切换到 Ubuntu 官方镜像。若修复后仍不可用，脚本会在生成 VPN 密钥或修改转发规则前退出。临时 DNS 修改不会在重启后保留，服务器的长期 DNS 故障需另行修复。

新服务器：在本地仓库目录执行（把 `SERVER_IP` 换成服务器公网 IP）：

```sh
scp scripts/install-amneziawg.sh root@SERVER_IP:/root/
ssh root@SERVER_IP 'bash /root/install-amneziawg.sh SERVER_IP'
```

已有本项目创建的旧配置：执行升级脚本。它要求现有模块和工具至少为 3.1，且拒绝覆盖已有的 `.pre-3.1` 备份。

```sh
scp scripts/upgrade-amneziawg-3.1.sh root@SERVER_IP:/root/
ssh root@SERVER_IP 'bash /root/upgrade-amneziawg-3.1.sh'
```

然后把服务器 `/root/awg-client.conf` 安全复制到本地，改用简短文件名（例如 `awg31.conf`）导入官方 AmneziaWG 3.1 客户端。升级后先关闭并删除旧隧道，再启用新隧道；旧客户端配置不再匹配。请妥善保管包含私钥的配置文件，导入后清理不需要的明文副本。

手机和 Mac 同时使用时，需要为 Mac 创建独立客户端。新增命令会自动分配下一个 `10.77.77.x/32` 地址、生成独立密钥、复制服务器的 3.1 混淆参数，并将新 Peer 写入服务器配置和运行中的接口；不会改动已有客户端。客户端名称限 1–15 个字母、数字、下划线或连字符。

```sh
scp scripts/add-amneziawg-client.sh root@SERVER_IP:/root/
ssh root@SERVER_IP 'bash /root/add-amneziawg-client.sh mac SERVER_IP'
scp root@SERVER_IP:/root/awg-clients/mac.conf ./mac.conf
chmod 600 ./mac.conf
```

在 Mac 上安装支持 3.1 的官方 AmneziaWG，选择 **Import tunnel(s) from file** 导入 `mac.conf`，再开启隧道。该文件含私钥；导入后清理不需要的明文副本。不要把手机的配置复制到 Mac 同时使用。

服务器侧可用 `systemctl is-active awg-quick@awg0` 和 `awg show awg0` 检查状态；客户端连接后应检查握手、DNS 和实际流量。脚本拒绝覆盖现有配置，重复执行安装脚本不是升级方式。

## UDP 中转

`scripts/setup-hk-relay.sh` 通过 SSH 在一台 Ubuntu 22.04 中转机上配置 UDP 转发，将中转端口收到的流量送到已有的 VPN 服务器。客户端先连接中转机，VPN 服务器仍负责隧道和公网出口。是否提速取决于实际线路，请比较直连与中转的延迟、丢包和吞吐。

在本地仓库目录执行，将占位符替换成自己的地址：

```sh
bash scripts/setup-hk-relay.sh root@RELAY_HOST VPN_SERVER_IPV4 51820 51820
```

四个参数依次是中转机 SSH 地址、VPN 服务器公网 IPv4、中转机 UDP 端口、VPN 服务器 UDP 端口；后两个端口可省略，默认均为 51820。需要 SSH 私钥时可在命令前加 `SSH_KEY=/path/to/key`。远程用户需要能以无需交互输入密码的 sudo 执行脚本。中转机需有 `ip` 和 `iptables`，且对应 UDP 入站端口须在云安全组和系统防火墙放行；VPN 服务器的 UDP 端口也需允许中转机访问。

在客户端原有配置的 `[Peer]` 中，将 `Endpoint` 改为 `RELAY_HOST:中转端口`，保留原有密钥与混淆参数，然后重新连接。检查中转机上的 `systemctl status awg-udp-relay.service`、VPN 服务器的 `awg show awg0`，并测试客户端实际访问。连接配置包含私钥，应妥善保管。

脚本通过 systemd 持久化规则，拒绝覆盖已有的同名服务。停止服务不会自动删除已添加的 iptables 规则或恢复 IPv4 转发设置；它也没有安装失败自动回滚。转发和 NAT 规则会影响中转机的防火墙行为，使用前应检查现有策略。中转功能由使用者报告已测试可用，本仓库尚未记录完整的端到端性能测试结果。

## 2026-11-04 服务器测试记录

- 测试机：Ubuntu 22.04.5，内核 `5.15.0-198-generic`。
- 首次安装因原软件源 `mirrors.cloud.aliyuncs.com` 无法解析，在依赖下载阶段退出。已备份服务器的 `/etc/apt/sources.list` 为 `/etc/apt/sources.list.pre-awg-test`，并将软件源改为 `archive.ubuntu.com`；临时将 `eth0` 的 DNS 改为 `1.1.1.1`、`8.8.8.8`。DNS 临时设置在重启后可能失效。
- 重试安装成功：`awg-quick@awg0` 为 `active` 且 `enabled`，`awg0` 地址为 `10.77.77.1/24`，UDP 51820 正在监听，IPv4 转发为 1，NAT/转发规则已添加。
- 服务器配置和客户端配置权限均为 `600`。客户端配置仅保存在服务器 `/root/awg-client.conf`，没有加入仓库。
- Android 真机（V2204）通过 ADB 安装官方 AmneziaWG `v3.1.20260814`，导入客户端配置并获得系统 VPN 授权。应用显示 `Connected`，系统建立 `tun0`，地址 `10.77.77.2/32`，默认 IPv4 路由指向隧道，DNS 为 `1.1.1.1`。
- 手机 ping 通 `10.77.77.1`、`1.1.1.1` 和域名 `example.com`，各 2/2 次成功；服务器端记录到握手及双向传输计数。由此确认该手机所在网络可通过 UDP 51820 连上服务器，但未直接读取云安全组规则或核对公网出口 IP。
- 首次导入时较长的配置文件名被客户端拒绝（“名称无效”）；改用 `test.conf` 后成功。手机“下载”目录和电脑临时目录中的明文配置副本已删除，导入的隧道仍保留在客户端内。

## 2026-11-04 AmneziaWG 3.1 升级验证

- 服务器模块和工具实际报告 `3.1.20260812`；Android 官方客户端为 `3.1.20260814`。服务器已运行新的配置：`S1-S4 = 16`、`H1-H4 = 1,2,3,4`、随机生成的 `HeaderProtectionKey`、`ContentPaddingAddition = 16-48`、`RandomTrailers = on`，同时保留 `Jc = 4`、`Jmin = 40`、`Jmax = 70`。服务端与客户端配置一致。
- 升级脚本在服务器上执行成功，`awg-quick@awg0` 为 `active`。Android 导入新配置后显示 `Connected`，流量经 `tun0`；`10.77.77.1`、`1.1.1.1`、`example.com` 各 3/3 次 ping 成功，服务器记录到新握手和双向流量。
- 重启 `awg-quick@awg0` 后，手机首次探测超时，随后自动恢复并再次 2/2 次 ping 通隧道地址。尚未测试整机重启。手机上已删除旧隧道，仅保留新的 `awg31` 隧道。

## 2026-11-04 新增客户端验证

- 在现有测试服务器上执行 `add-amneziawg-client.sh mac SERVER_IP`（将 `SERVER_IP` 换成服务器公网 IP），生成独立的 `/root/awg-clients/mac.conf`，权限为 `600`，目录权限为 `700`。Mac 使用 `10.77.77.3/32`，Android 保持 `10.77.77.2/32`。
- 新客户端的 3.1 参数与服务器逐项一致。服务重启后两个 Peer 均保留；Android 的首次探测短暂超时，随后访问 `example.com` 成功。重复执行同名新增命令被拒绝，Peer 数保持为 2。
- 尚未在 macOS 客户端导入配置和建立 Mac 握手；服务器侧新增命令已验证，Mac 端连接仍待验证。
