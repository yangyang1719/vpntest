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

服务器侧可用 `systemctl is-active awg-quick@awg0` 和 `awg show awg0` 检查状态；客户端连接后应检查握手、DNS 和实际流量。脚本拒绝覆盖现有配置，重复执行安装脚本不是升级方式。

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
