# VPS TCP/BBR Optimizer

一个偏保守的一键 VPS TCP/BBR 优化脚本，目标不是“堆最多参数”，而是先检测机器能力，再按带宽、RTT、内存和当前内核能力生成更稳妥的 sysctl 配置。

它参考了这些项目的使用方式和思路，但实现上更偏向“默认安全、显式 apply、支持回滚”：

- [Omnitt TCP 调参](https://omnitt.com/)
- [Eric86777/vps-tcp-tune](https://github.com/Eric86777/vps-tcp-tune)
- [vpszdm.com 的 bbr.sh](https://vpszdm.com/bbr.sh)
- [jiaqp/one_swap 的 bbr-auto-tune.sh](https://raw.githubusercontent.com/jiaqp/one_swap/refs/heads/main/bbr-auto-tune.sh)

## 特点

- 自动检测发行版、内核、虚拟化、CPU、内存、Swap、默认网卡、MTU、当前 qdisc、当前拥塞控制算法。
- 可选做轻量 RTT 探测，并结合带宽与内存估算更合适的缓冲区。
- 默认优先启用 `fq + bbr`；如果当前内核没有 `bbr`，会自动回退到当前算法或 `cubic`。
- 默认只改相对安全且有明确官方文档依据的项，比如 `tcp_mtu_probing=1`、`tcp_slow_start_after_idle=0`、`tcp_fastopen=3`、`tcp_sack=1`、`rp_filter=2`。
- 不默认做高风险动作，比如强装第三方内核、全局 `tcp_tw_reuse=1`、关闭 `ip_forward`、大幅改 VM 策略。
- 写入前自动备份，支持 `--rollback`。

## 快速开始

先给脚本执行权限：

```bash
chmod +x /Users/shaolong/Code/personal/vps-tcp-bbr-optimizer/vps-tcp-bbr-optimizer.sh
```

仅检测并输出建议：

```bash
bash /Users/shaolong/Code/personal/vps-tcp-bbr-optimizer/vps-tcp-bbr-optimizer.sh --report --print-config
```

交互式一键检测，最后询问是否应用：

```bash
sudo bash /Users/shaolong/Code/personal/vps-tcp-bbr-optimizer/vps-tcp-bbr-optimizer.sh
```

非交互直接应用：

```bash
sudo bash /Users/shaolong/Code/personal/vps-tcp-bbr-optimizer/vps-tcp-bbr-optimizer.sh --apply --yes
```

回滚最近一次备份：

```bash
sudo bash /Users/shaolong/Code/personal/vps-tcp-bbr-optimizer/vps-tcp-bbr-optimizer.sh --rollback
```

## 常用参数

```bash
sudo bash /Users/shaolong/Code/personal/vps-tcp-bbr-optimizer/vps-tcp-bbr-optimizer.sh \
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
- `--rollback` 会恢复最近一份备份，并重新加载系统 sysctl

## 建议的使用顺序

1. 先跑 `--report --print-config` 看推荐值。
2. 确认当前业务不是强依赖特殊路由或特殊内核参数。
3. 再用 `--apply` 落盘和生效。
4. 用 `sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc` 和 `tc qdisc show dev <网卡>` 做复核。

## 参考依据

实现时除了上面的示例脚本，也刻意对照了官方文档来避免一些常见的激进写法：

- [Linux Kernel `ip-sysctl` 文档](https://docs.kernel.org/networking/ip-sysctl.html)
- [`tc-fq(8)` 手册](https://man7.org/linux/man-pages/man8/tc-fq.8.html)
