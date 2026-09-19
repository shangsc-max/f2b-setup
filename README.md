# f2b-setup

一键安装并配置 [fail2ban](https://github.com/fail2ban/fail2ban),自动封禁暴力破解 SSH 的 IP。

一条命令搞定:安装、检测 SSH 端口、写入配置、启动并设置开机自启。

## 快速开始

在服务器上用 **root** 执行:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/shangsc-max/f2b-setup/main/f2b.sh)
```

不是 root 用户:

```bash
curl -fsSL https://raw.githubusercontent.com/shangsc-max/f2b-setup/main/f2b.sh | sudo bash
```

没有 curl:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/shangsc-max/f2b-setup/main/f2b.sh)
```

> 安全提示:直接执行网络上的脚本前,建议先打开链接看一遍内容,确认无误再运行。

## 默认行为

| 项目 | 默认值 |
| --- | --- |
| 保护对象 | SSH(`sshd` jail) |
| 统计窗口 `findtime` | 10 分钟 |
| 最大失败次数 `maxretry` | 5 次 |
| 封禁时长 `bantime` | 1 小时 |
| SSH 端口 | 自动检测,检测不到用 22 |
| 白名单 | `127.0.0.1/8`、`::1`,以及你当前 SSH 登录的 IP |

也就是说:同一个 IP 在 10 分钟内登录失败 5 次,就会被封 1 小时。

## 功能特点

- **一键安装**:自动识别 `apt`、`dnf`、`yum`,RHEL 系会先装 EPEL。
- **自动防误封**:通过 SSH 登录时,自动把你当前的 IP 加入白名单。
- **配置前先备份**:旧的 `jail.local` 会备份为 `jail.local.bak.<时间>`,校验或启动失败时自动恢复。
- **自动回退**:`systemd` 日志后端无法启动时,自动改用 `auto` 后端重试。
- **可重复运行**:配置没有变化时不会重复写入。
- **参数校验**:输入格式有误会在动手安装前就报错。
- **自带状态查看与卸载**。

## 自定义参数

```bash
bash f2b.sh [选项]
```

| 选项 | 说明 | 默认 |
| --- | --- | --- |
| `-i, --ignoreip <IP>` | 加入白名单的 IP 或网段,可多次使用,或用空格/逗号分隔 | 空 |
| `-b, --bantime <时长>` | 封禁时长,如 `30m`、`1h`、`1d`、`1w`,`-1` 为永久 | `1h` |
| `-f, --findtime <时长>` | 统计失败次数的时间窗口 | `10m` |
| `-m, --maxretry <次数>` | 窗口内允许的最大失败次数 | `5` |
| `-p, --port <端口>` | SSH 端口,多个用逗号分隔,如 `22,2222` | 自动检测 |
| `--no-auto-ignore` | 不自动把当前登录 IP 加入白名单 | 关闭 |
| `--status` | 查看 sshd jail 状态与被封 IP | |
| `--uninstall` | 卸载 fail2ban 并删除本脚本生成的配置 | |
| `-y, --yes` | 跳过确认提示(用于卸载) | |
| `-v, --version` | 显示版本 | |
| `-h, --help` | 显示帮助 | |

通过管道运行时,选项写在 `bash -s --` 后面:

```bash
# 封禁 1 天,失败 3 次就封,并加白名单
curl -fsSL https://raw.githubusercontent.com/shangsc-max/f2b-setup/main/f2b.sh \
  | sudo bash -s -- -b 1d -m 3 -i "1.2.3.4 10.0.0.0/8"
```

也可以用环境变量(以 root 运行时):

```bash
BANTIME=1d MAXRETRY=3 IGNOREIP="1.2.3.4" bash f2b.sh
```

支持的环境变量:`BANTIME`、`FINDTIME`、`MAXRETRY`、`IGNOREIP`、`SSH_PORT`。

## 验证是否生效

```bash
systemctl status fail2ban          # 显示 active (running) 即正常
fail2ban-client status sshd        # 查看 sshd 规则与被封 IP
tail -n 50 /var/log/fail2ban.log   # 查看封禁/解封日志
```

`Currently banned` 为 0 说明暂时没有人被封,属于正常。公网服务器通常几小时内就会出现被封的 IP。

## 常用命令

```bash
fail2ban-client status sshd                # 查看被封 IP
fail2ban-client set sshd unbanip 1.2.3.4   # 手动解封
bash f2b.sh --status                       # 用本脚本查看状态
bash f2b.sh --uninstall                    # 卸载
```

## 支持的系统

| 系统 | 包管理器 |
| --- | --- |
| Debian / Ubuntu | `apt` |
| RHEL / CentOS / Rocky / AlmaLinux / Fedora | `dnf` / `yum` |

需要 root 权限。封禁动作使用 fail2ban 在该系统上的默认设置。

## 注意事项

1. **重新运行会覆盖 `/etc/fail2ban/jail.local`。** 你手动改过的内容会被重置(旧文件已自动备份)。想长期保留自定义配置,请直接修改脚本,或者用命令行参数传入。
2. **别把自己封了。** 建议把常用 IP 用 `-i` 加进白名单。如果不慎被封,可以通过服务商的网页控制台(VNC)登录后执行 `fail2ban-client set sshd unbanip <你的IP>`。
3. **修改了 SSH 端口?** 脚本会自动检测 `sshd` 的端口;如果检测不准,用 `-p` 手动指定。
4. **国内服务器访问 GitHub 可能超时。** 可以先在本地下载 `f2b.sh`,再上传到服务器执行,或使用可用的 GitHub 加速镜像。
5. 卸载不会影响你服务器上其他的防火墙规则。

## 常见问题

**启动失败怎么办?**
脚本会自动恢复旧配置。之后查看日志排查:

```bash
journalctl -u fail2ban -n 50 --no-pager
```

**怎么改封禁时长?**
重新运行脚本并带上 `-b`,例如 `bash f2b.sh -b 24h`。

**能保护 SSH 以外的服务吗?**
当前版本只配置 SSH。其他服务(如 Nginx)可以自己在 `/etc/fail2ban/jail.local` 里追加 jail,但下次重新运行脚本时会被覆盖,追加后请不要再运行脚本。

## 许可证

未指定许可证。如需开放使用,可在仓库中添加 LICENSE 文件(如 MIT)。
