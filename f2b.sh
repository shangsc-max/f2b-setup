#!/usr/bin/env bash
#
# f2b-setup —— fail2ban 一键安装与配置脚本(保护 SSH)
#
# 用法:
#   sudo bash f2b.sh [选项]
#   curl -fsSL <raw链接> | sudo bash -s -- [选项]
#
# 支持系统:Debian / Ubuntu(apt)、RHEL / CentOS / Rocky / Alma / Fedora(dnf、yum)
# 完整选项见:bash f2b.sh --help
#
set -Eeuo pipefail

readonly VERSION="1.0.0"
readonly JAIL_LOCAL="/etc/fail2ban/jail.local"
readonly MARKER="# Managed by f2b-setup"

# ---------- 默认参数(可被环境变量或命令行覆盖) ----------
BANTIME="${BANTIME:-1h}"
FINDTIME="${FINDTIME:-10m}"
MAXRETRY="${MAXRETRY:-5}"
IGNOREIP="${IGNOREIP:-}"
SSH_PORT="${SSH_PORT:-}"
AUTO_IGNORE=1
ASSUME_YES=0
ACTION="install"

# ---------- 运行时状态 ----------
PKG=""
BACKEND=""
BACKUP=""
TMP=""

# ---------- 输出工具 ----------
if [[ -t 1 ]]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'; C_0=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""
fi
info() { printf '%s[信息]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[完成]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err()  { printf '%s[错误]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()  { err "$*"; exit 1; }

cleanup() { rm -f -- "${TMP:-}"; }
trap cleanup EXIT
trap 'err "脚本在第 ${LINENO} 行异常退出(退出码 $?)"' ERR

usage() {
  cat <<EOF
f2b-setup v${VERSION} —— fail2ban 一键安装与配置(保护 SSH)

用法:
  bash f2b.sh [选项]

选项:
  -i, --ignoreip <IP>    加入白名单的 IP 或网段,可多次使用,或用空格/逗号分隔
  -b, --bantime  <时长>  封禁时长,默认 ${BANTIME}(如 30m、1h、1d、1w;-1 表示永久)
  -f, --findtime <时长>  统计失败次数的时间窗口,默认 ${FINDTIME}
  -m, --maxretry <次数>  窗口内允许的最大失败次数,默认 ${MAXRETRY}
  -p, --port <端口>      SSH 端口,多个用逗号分隔;默认自动检测,检测不到用 22
      --no-auto-ignore   不自动把当前 SSH 登录 IP 加入白名单
      --status           查看 sshd jail 当前状态与被封 IP
      --uninstall        卸载 fail2ban 并删除本脚本生成的配置
  -y, --yes              跳过确认提示(用于卸载)
  -v, --version          显示版本
  -h, --help             显示本帮助

环境变量:BANTIME、FINDTIME、MAXRETRY、IGNOREIP、SSH_PORT 与对应选项等效。

示例:
  bash f2b.sh
  bash f2b.sh -i "1.2.3.4 10.0.0.0/8" -b 1d -m 3
  curl -fsSL https://raw.githubusercontent.com/shangsc-max/f2b-setup/main/f2b.sh | sudo bash -s -- -b 1d -m 3
EOF
}

need_val() { [[ $# -ge 2 && -n $2 ]] || die "选项 $1 缺少参数"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--ignoreip)     need_val "$@"; IGNOREIP="$IGNOREIP $2"; shift 2 ;;
      -b|--bantime)      need_val "$@"; BANTIME="$2";   shift 2 ;;
      -f|--findtime)     need_val "$@"; FINDTIME="$2";  shift 2 ;;
      -m|--maxretry)     need_val "$@"; MAXRETRY="$2";  shift 2 ;;
      -p|--port)         need_val "$@"; SSH_PORT="$2";  shift 2 ;;
      --no-auto-ignore)  AUTO_IGNORE=0; shift ;;
      --status)          ACTION="status"; shift ;;
      --uninstall)       ACTION="uninstall"; shift ;;
      -y|--yes)          ASSUME_YES=1; shift ;;
      -v|--version)      echo "f2b-setup v${VERSION}"; exit 0 ;;
      -h|--help)         usage; exit 0 ;;
      *)                 die "未知选项:$1(使用 --help 查看用法)" ;;
    esac
  done
}

require_root() {
  [[ $EUID -eq 0 ]] || die "请使用 root 运行(或在命令前加 sudo)"
}

# ---------- 参数校验 ----------
validate_inputs() {
  local p
  [[ $MAXRETRY =~ ^[0-9]+$ ]] && (( 10#$MAXRETRY >= 1 )) \
    || die "maxretry 必须是大于 0 的整数:$MAXRETRY"
  [[ $BANTIME =~ ^-?([0-9]+[smhdw]?)+$ ]] \
    || die "bantime 格式无效:$BANTIME(示例:30m、1h、1d、-1)"
  [[ $FINDTIME =~ ^([0-9]+[smhdw]?)+$ ]] \
    || die "findtime 格式无效:$FINDTIME(示例:10m、1h)"
  if [[ -n $SSH_PORT ]]; then
    [[ $SSH_PORT =~ ^[0-9]+(,[0-9]+)*$ ]] || die "端口格式无效:$SSH_PORT(示例:22 或 22,2222)"
    for p in ${SSH_PORT//,/ }; do
      (( 10#$p >= 1 && 10#$p <= 65535 )) || die "端口超出范围:$p"
    done
  fi
}

# 规范化白名单:逗号转空格、去重、逐项校验
normalize_ignoreip() {
  local tok norm=""
  set -f
  for tok in ${IGNOREIP//,/ }; do
    if [[ ! $tok =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]]; then
      set +f
      die "无效的 IP 或网段:$tok"
    fi
    if [[ " $norm " != *" $tok "* ]]; then
      norm+=" $tok"
    fi
  done
  set +f
  IGNOREIP="${norm# }"
}

# ---------- 环境探测 ----------
detect_pkg() {
  if   command -v apt-get >/dev/null 2>&1; then PKG="apt"
  elif command -v dnf     >/dev/null 2>&1; then PKG="dnf"
  elif command -v yum     >/dev/null 2>&1; then PKG="yum"
  else die "不支持的系统:未找到 apt-get / dnf / yum"
  fi
}

detect_backend() {
  if [[ -d /run/systemd/system ]] && command -v journalctl >/dev/null 2>&1; then
    echo "systemd"
  else
    echo "auto"
  fi
}

detect_ssh_port() {
  local ports=""
  if command -v sshd >/dev/null 2>&1; then
    ports=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un | paste -sd, -) || true
  fi
  echo "${ports:-22}"
}

# 通过 SSH 登录时,取当前客户端 IP,避免把自己封掉
detect_client_ip() {
  local ip=""
  if   [[ -n ${SSH_CONNECTION:-} ]]; then ip="${SSH_CONNECTION%% *}"
  elif [[ -n ${SSH_CLIENT:-}     ]]; then ip="${SSH_CLIENT%% *}"
  else ip=$(who -m 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p;q') || true
  fi
  if [[ $ip =~ ^[0-9a-fA-F:.]+$ ]]; then echo "$ip"; fi
}

# ---------- 安装 ----------
install_fail2ban() {
  if command -v fail2ban-client >/dev/null 2>&1; then
    ok "fail2ban 已安装:$(fail2ban-client --version 2>&1 | sed -n 1p)"
  else
    info "正在通过 ${PKG} 安装 fail2ban ..."
    case "$PKG" in
      apt)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y fail2ban
        ;;
      dnf|yum)
        "$PKG" install -y epel-release || warn "epel-release 安装失败,继续尝试直接安装 fail2ban"
        "$PKG" install -y fail2ban
        ;;
    esac
    ok "fail2ban 安装完成"
  fi

  # Debian/Ubuntu 的 systemd 后端依赖 python3-systemd
  if [[ $PKG == "apt" && $BACKEND == "systemd" ]]; then
    if ! dpkg -s python3-systemd >/dev/null 2>&1; then
      apt-get install -y python3-systemd || warn "python3-systemd 安装失败,稍后可能回退到 auto 后端"
    fi
  fi
}

# ---------- 配置 ----------
render_config() {  # $1 = backend
  cat <<EOF
${MARKER} v${VERSION}
# Manual edits are overwritten when the script is re-run.
# The previous file is backed up as jail.local.bak.<timestamp>.
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1${IGNOREIP:+ ${IGNOREIP}}
bantime  = ${BANTIME}
findtime = ${FINDTIME}
maxretry = ${MAXRETRY}
backend  = $1

[sshd]
enabled = true
port    = ${SSH_PORT}
EOF
}

backup_existing() {
  if [[ -f $JAIL_LOCAL && -z $BACKUP ]]; then
    BACKUP="${JAIL_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$JAIL_LOCAL" "$BACKUP"
    info "已备份旧配置 → ${BACKUP}"
  fi
}

restore_config() {
  if [[ -n $BACKUP && -f $BACKUP ]]; then
    cp -a "$BACKUP" "$JAIL_LOCAL"
    warn "已恢复旧配置"
  else
    rm -f "$JAIL_LOCAL"
  fi
}

restart_service() {
  if [[ -d /run/systemd/system ]]; then
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban
  else
    service fail2ban restart
  fi
}

wait_jail() {
  local i
  for i in $(seq 1 15); do
    if fail2ban-client status sshd >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

apply_config() {
  local b out backends="auto" success=0
  [[ $BACKEND == "systemd" ]] && backends="systemd auto"
  TMP=$(mktemp)

  for b in $backends; do
    render_config "$b" > "$TMP"
    if [[ -f $JAIL_LOCAL ]] && cmp -s "$TMP" "$JAIL_LOCAL"; then
      info "配置无变化(backend=${b})"
    else
      backup_existing
      install -m 0644 "$TMP" "$JAIL_LOCAL"
      info "已写入 ${JAIL_LOCAL}(backend=${b})"
    fi

    out=$(fail2ban-client -t 2>&1) || {
      err "配置校验未通过:"
      printf '%s\n' "$out" >&2
      restore_config
      die "已中止,请检查参数后重试"
    }

    if restart_service && wait_jail; then
      success=1
      BACKEND="$b"
      break
    fi
    warn "backend=${b} 时 sshd jail 未能启动"
  done

  if [[ $success -ne 1 ]]; then
    restore_config
    restart_service || true
    err "fail2ban 启动失败,可查看日志:journalctl -u fail2ban -n 50 --no-pager"
    exit 1
  fi
}

# ---------- 动作 ----------
show_summary() {
  echo
  ok "fail2ban 已就绪"
  printf '  SSH 端口 : %s\n' "$SSH_PORT"
  printf '  封禁时长 : %s\n' "$BANTIME"
  printf '  统计窗口 : %s\n' "$FINDTIME"
  printf '  最大失败 : %s 次\n' "$MAXRETRY"
  printf '  白名单   : 127.0.0.1/8 ::1%s\n' "${IGNOREIP:+ ${IGNOREIP}}"
  printf '  日志后端 : %s\n' "$BACKEND"
  echo
  fail2ban-client status sshd || true
  echo
  echo "常用命令:"
  echo "  fail2ban-client status sshd                  # 查看被封 IP"
  echo "  fail2ban-client set sshd unbanip <IP>        # 手动解封"
  echo "  tail -n 50 /var/log/fail2ban.log             # 查看日志"
}

do_install() {
  local client
  detect_pkg
  validate_inputs
  BACKEND=$(detect_backend)
  if [[ -z $SSH_PORT ]]; then
    SSH_PORT=$(detect_ssh_port)
  fi

  if [[ $AUTO_IGNORE -eq 1 ]]; then
    client=$(detect_client_ip)
    if [[ -n $client ]]; then
      IGNOREIP="$IGNOREIP $client"
      info "已将当前登录 IP 加入白名单:${client}"
    fi
  fi
  normalize_ignoreip

  install_fail2ban
  apply_config
  show_summary
}

do_status() {
  command -v fail2ban-client >/dev/null 2>&1 || die "未安装 fail2ban"
  fail2ban-client status sshd || die "sshd jail 未运行"
}

confirm() {
  local ans
  if [[ $ASSUME_YES -eq 1 ]]; then
    return 0
  fi
  if read -r -p "$1 [y/N] " ans </dev/tty 2>/dev/null; then
    [[ $ans =~ ^[Yy]$ ]]
  else
    die "当前为非交互环境,请加 -y 确认"
  fi
}

do_uninstall() {
  detect_pkg
  if ! confirm "将停止并卸载 fail2ban,同时删除本脚本生成的配置。继续吗?"; then
    info "已取消"
    return 0
  fi
  if [[ -d /run/systemd/system ]]; then
    systemctl disable --now fail2ban >/dev/null 2>&1 || true
  else
    service fail2ban stop || true
  fi
  case "$PKG" in
    apt)     apt-get purge -y fail2ban ;;
    dnf|yum) "$PKG" remove -y fail2ban ;;
  esac
  if [[ -f $JAIL_LOCAL ]] && grep -qF "$MARKER" "$JAIL_LOCAL"; then
    rm -f "$JAIL_LOCAL"
  fi
  ok "fail2ban 已卸载"
}

main() {
  parse_args "$@"
  require_root
  case "$ACTION" in
    install)   do_install ;;
    status)    do_status ;;
    uninstall) do_uninstall ;;
  esac
}

# 放在最后一行:通过管道下载被中途截断时,不会执行不完整的脚本
main "$@"
