# VPS TCP/BBR Optimizer

一个偏保守的一键 VPS TCP/BBR 优化脚本，目标不是“堆最多参数”，而是先检测机器能力，再按带宽、RTT、内存和当前内核能力生成更稳妥的 sysctl 配置。

当前实现面向这些 Linux 发行版做了兼容处理：

- Alpine
- Debian
- Ubuntu
- CentOS
- RHEL
- Fedora

它参考了这些项目的使用方式和思路，但实现上更偏向“默认安全、显式 apply、支持回滚”：

- [Omnitt TCP 调参](https://omnitt.com/)
- [Eric86777/vps-tcp-tune](https://github.com/Eric86777/vps-tcp-tune)
- [vpszdm.com 的 bbr.sh](https://vpszdm.com/bbr.sh)
- [jiaqp/one_swap 的 bbr-auto-tune.sh](https://raw.githubusercontent.com/jiaqp/one_swap/refs/heads/main/bbr-auto-tune.sh)

## 特点

- 入口脚本改为 `/bin/sh` 启动，自带 Bash bootstrap；像 Alpine 这类默认没有 Bash 的系统，脚本会在 root 环境下自动尝试安装 Bash 后继续执行。
- 自动检测发行版、内核、虚拟化、CPU、内存、Swap、默认网卡、MTU、当前 qdisc、当前拥塞控制算法。
- 会对关键依赖做跨发行版检查；缺少 `ip` / `sysctl` 这类硬依赖时，会按发行版自动尝试安装。
- 可选做轻量 RTT 探测，并结合带宽与内存估算更合适的缓冲区。
- 默认优先启用 `fq + bbr`；如果当前内核没有 `bbr`，会自动回退到当前算法或 `cubic`。
- 默认只改相对安全且有明确官方文档依据的项，比如 `tcp_mtu_probing=1`、`tcp_slow_start_after_idle=0`、`tcp_fastopen=3`、`tcp_sack=1`、`rp_filter=2`。
- 不默认做高风险动作，比如强装第三方内核、全局 `tcp_tw_reuse=1`、关闭 `ip_forward`、大幅改 VM 策略。
- 写入前自动备份，支持 `--rollback`。
- 回滚和配置重载不再依赖 `sysctl --system`，因此 Alpine/BusyBox 环境也能走可移植的逐文件加载路径。

## 快速开始

在线一键运行：

```bash
curl -fsSL https://raw.githubusercontent.com/shaolonger/vps-tcp-bbr-optimizer/main/install.sh | sudo sh
```

在线一键直接应用：

```bash
curl -fsSL https://raw.githubusercontent.com/shaolonger/vps-tcp-bbr-optimizer/main/install.sh | sudo sh -s -- --apply --yes
```

在线一键回滚：

```bash
curl -fsSL https://raw.githubusercontent.com/shaolonger/vps-tcp-bbr-optimizer/main/install.sh | sudo sh -s -- --rollback
```

如果你更习惯 `wget`：

```bash
wget -qO- https://raw.githubusercontent.com/shaolonger/vps-tcp-bbr-optimizer/main/install.sh | sudo sh -s -- --apply --yes
```

先给脚本执行权限：

```bash
chmod +x /Users/shaolong/Code/personal/vps-tcp-bbr-optimizer/vps-tcp-bbr-optimizer.sh
```

仅检测并输出建议：

```bash
sh /Users/shaolong/Code/personal/vps-tcp-bbr-optimizer/vps-tcp-bbr-optimizer.sh --report --print-config
```

交互式一键检测，最后询问是否应用：

```bash
sudo sh /Users/shaolong/Code/personal/vps-tcp-bbr-optimizer/vps-tcp-bbr-optimizer.sh
```

非交互直接应用：

```bash
sudo sh /Users/shaolong/Code/personal/vps-tcp-bbr-optimizer/vps-tcp-bbr-optimizer.sh --apply --yes
```

回滚最近一次备份：

```bash
sudo sh /Users/shaolong/Code/personal/vps-tcp-bbr-optimizer/vps-tcp-bbr-optimizer.sh --rollback
```

## 常用参数

```bash
sudo sh /Users/shaolong/Code/personal/vps-tcp-bbr-optimizer/vps-tcp-bbr-optimizer.sh \
  --apply \
  --region us \
  --profile throughput \
  --bandwidth 1000 \
  --rtt 140 \
  --concurrency 4096
```

- `--region`: `china | asia | us | eu | global`
- `--profile`: `balanced | throughput | latency`
- `--bandwidth`: 手动指定套餐或链路带宽，单位 Mbps
- `--rtt`: 手动指定典型 RTT，单位毫秒
- `--no-network-test`: 不做 ping 探测，直接使用地区默认 RTT
- `--print-config`: 顺手打印将写入的 sysctl 配置
- `--json`: 输出 JSON，方便接入别的自动化流程

## 在线入口说明

- GitHub Raw 在线入口脚本是 [install.sh](https://raw.githubusercontent.com/shaolonger/vps-tcp-bbr-optimizer/main/install.sh)
- 它会先下载仓库里的主脚本 `vps-tcp-bbr-optimizer.sh` 到临时文件，再执行
- 因此适合 `curl | sh`、`wget | sh` 这类一次性运行方式
- 需要传参时，使用 `sh -s -- ...` 的形式

## 一键对比报告

安装前先运行一次，保存基线：

```bash
curl -fsSL https://raw.githubusercontent.com/shaolonger/vps-tcp-bbr-optimizer/main/verify.sh | sudo sh
```

执行优化脚本后，再运行同一条命令：

```bash
curl -fsSL https://raw.githubusercontent.com/shaolonger/vps-tcp-bbr-optimizer/main/verify.sh | sudo sh
```

第二次运行会自动读取第一次保存的基线，并在控制台输出前后对比报告。

如果只想查看当前状态和已安装配置是否一致：

```bash
curl -fsSL https://raw.githubusercontent.com/shaolonger/vps-tcp-bbr-optimizer/main/verify.sh | sudo sh -s -- --current-only
```

如果想重置基线，重新开始一轮对比：

```bash
curl -fsSL https://raw.githubusercontent.com/shaolonger/vps-tcp-bbr-optimizer/main/verify.sh | sudo sh -s -- --reset
```

### 对比报告会看什么

- 优化前后的关键 sysctl 项变化
- 当前值与 `/etc/sysctl.d/99-vps-tcp-bbr-optimizer.conf` 的一致性
- Root qdisc 变化
- 可选的 ping 平均延迟变化

### 注意

- `verify.sh` 不会修改 TCP/BBR 配置，只会读取当前系统状态并生成报告
- 如果 root qdisc 显示为 `mq`，不一定代表没生效；多队列网卡上这是常见现象
- 基线和当前快照默认保存在 `/var/lib/vps-tcp-bbr-optimizer/verify/`

## 当前会调整的重点项

- `net.core.default_qdisc = fq`
- `net.ipv4.tcp_congestion_control = bbr`（当前内核支持时）
- `net.core.rmem_max / wmem_max`
- `net.ipv4.tcp_rmem / tcp_wmem`
- `net.core.somaxconn`
- `net.core.netdev_max_backlog`
- `net.ipv4.tcp_max_syn_backlog`
- `net.ipv4.tcp_mtu_probing = 1`
- `net.ipv4.tcp_slow_start_after_idle = 0`
- `net.ipv4.tcp_fastopen = 3`
- `net.ipv4.tcp_notsent_lowat`
- `net.ipv4.tcp_sack = 1`
- `net.ipv4.tcp_window_scaling = 1`
- `net.ipv4.tcp_syncookies = 1`
- 一组较稳妥的 IPv4/IPv6 redirect/source-route 安全项

## 为什么没有默认做这些事

- 不自动安装 XanMod/第三方内核：这类动作收益和风险都更大，适合单独确认后再做。
- 不强行改 `tcp_tw_reuse=1`：Linux 官方文档明确提示不应随意改这个值。
- 不改 `ip_forward`：许多 VPS 还跑着 Docker、TProxy、NAT 或旁路网关，盲改可能直接影响业务。
- 不做大幅 VM 调优：这个仓库目前聚焦 TCP/BBR 和基础安全项，不想把网络脚本变成一键“系统全改”脚本。

## 生成文件与回滚

- 持久化配置默认写到 `/etc/sysctl.d/99-vps-tcp-bbr-optimizer.conf`
- 备份默认存到 `/var/lib/vps-tcp-bbr-optimizer/backups/`
- `--rollback` 会恢复最近一份备份，并重新加载配置
- 在不支持 `sysctl --system` 的环境里，会自动回退到逐文件 `sysctl -p` 的可移植加载方式

## 建议的使用顺序

1. 先跑 `--report --print-config` 看推荐值。
2. 确认当前业务不是强依赖特殊路由或特殊内核参数。
3. 再用 `--apply` 落盘和生效。
4. 用 `sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc` 和 `tc qdisc show dev <网卡>` 做复核。

## 兼容说明

- Alpine 默认没有 Bash，脚本会先用 `/bin/sh` 启动，再自动补齐 Bash。
- Alpine 最小环境若缺少 `ip`，脚本会尝试安装 `iproute2-minimal`。
- `ping`、`tc`、`ethtool` 被视为可选依赖；缺失时脚本会降级运行，而不是直接退出。
- RTT 探测对 BusyBox `ping` 做了兼容处理；如果仍然探测失败，会退回地区默认 RTT。

## 参考依据

实现时除了上面的示例脚本，也刻意对照了官方文档来避免一些常见的激进写法：

- [Linux Kernel `ip-sysctl` 文档](https://docs.kernel.org/networking/ip-sysctl.html)
- [`tc-fq(8)` 手册](https://man7.org/linux/man-pages/man8/tc-fq.8.html)
