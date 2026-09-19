#!/usr/bin/env bash
# 一键安装并配置 fail2ban(保护 SSH)
set -e

[ "$EUID" -ne 0 ] && { echo "请用 root 运行"; exit 1; }

# 1. 安装
if command -v apt-get >/dev/null; then
  apt-get update && apt-get install -y fail2ban
elif command -v dnf >/dev/null; then
  dnf install -y epel-release && dnf install -y fail2ban
elif command -v yum >/dev/null; then
  yum install -y epel-release && yum install -y fail2ban
else
  echo "不支持的系统"; exit 1
fi

# 2. 自动检测 SSH 端口(检测不到就用 22)
SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
SSH_PORT=${SSH_PORT:-22}

# 3. 写配置(不改动默认的 jail.conf,升级时不会被覆盖)
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
port    = ${SSH_PORT}
EOF

# 4. 启动并设为开机自启
systemctl enable --now fail2ban
systemctl restart fail2ban

echo "完成!SSH 端口: ${SSH_PORT}"
fail2ban-client status sshd