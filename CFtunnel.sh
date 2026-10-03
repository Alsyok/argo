#!/bin/sh
# Cloudflare Tunnel manager: Alpine/OpenRC and Debian/systemd
set -eu
VERSION=1.0.0
BASE=/etc/vps-tunnel
BIN=/usr/local/lib/vps-tunnel/cloudflared
SERVICE=vps-tunnel
LOG=/var/log/vps-tunnel/cloudflared.log
TMP=
cleanup() { [ -z "$TMP" ] || rm -rf "$TMP"; }
trap cleanup EXIT
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
ask() { printf '%s' "$1" >&2; IFS= read -r REPLY || exit 0; }
detect() {
    [ "$(id -u)" = 0 ] || die '请使用 root 运行。'
    [ -f /etc/os-release ] || die '无法识别系统。'
    . /etc/os-release
    case "$ID" in
        alpine) MANAGER=openrc; command -v rc-service >/dev/null || die '需要 OpenRC。';;
        debian|ubuntu) MANAGER=systemd; [ -d /run/systemd/system ] || die '需要运行中的 systemd；不支持无 init 的容器。';;
        *) die '仅支持 Alpine、Debian 和 Ubuntu。';;
    esac
    case "$(uname -m)" in
        x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;;
        *) die '仅支持 AMD64 / ARM64。';;
    esac
}
dependencies() {
    if [ "$MANAGER" = openrc ]; then
        apk add --no-cache curl ca-certificates
    else
        apt-get update
        apt-get install -y curl ca-certificates
    fi
}
download() {
    dependencies
    TMP=$(mktemp -d)
    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH"
    curl -fL --retry 3 --connect-timeout 15 --max-time 300 "$url" -o "$TMP/cloudflared"
    chmod 755 "$TMP/cloudflared"
    "$TMP/cloudflared" --version || die '下载的程序无法运行。'
    mkdir -p /usr/local/lib/vps-tunnel
    mv "$TMP/cloudflared" "$BIN"
    cleanup; TMP=
}
exists() { [ -f "$BASE/mode" ]; }
control() {
    if [ "$MANAGER" = openrc ]; then rc-service "$SERVICE" "$1"
    else systemctl "$1" "$SERVICE.service"; fi
}
confirm_replace() {
    if exists; then
        ask '已有本脚本管理的隧道。替换配置？输入 YES 确认：'
        [ "$REPLY" = YES ] || return 1
    fi
}
write_runner() {
    cat > "$BASE/run" <<'RUN'
#!/bin/sh
set -eu
BASE=/etc/vps-tunnel
BIN=/usr/local/lib/vps-tunnel/cloudflared
cd "$BASE"
# Quick Tunnel must not inherit ~/.cloudflared/config.yaml.
export HOME="$BASE/home"
mode=$(cat "$BASE/mode")
if [ "$mode" = quick ]; then
    # Clear stale addresses on every new process launch.
    : > /var/log/vps-tunnel/cloudflared.log
    port=$(cat "$BASE/port")
    exec "$BIN" tunnel --no-autoupdate --loglevel info --log-directory /var/log/vps-tunnel --url "http://127.0.0.1:$port"
else
    exec "$BIN" tunnel --no-autoupdate --loglevel info --log-directory /var/log/vps-tunnel run --token-file "$BASE/token"
fi
RUN
    chmod 700 "$BASE/run"
}
write_service() {
    if [ "$MANAGER" = openrc ]; then
        cat > /etc/init.d/vps-tunnel <<'RC'
#!/sbin/openrc-run
name="Cloudflare Tunnel (VPS toolbox)"
description="Managed Cloudflare Tunnel with automatic restart"
supervisor="supervise-daemon"
command="/etc/vps-tunnel/run"
respawn_delay=5
respawn_max=0
respawn_period=60
output_log="/var/log/vps-tunnel-service.log"
error_log="/var/log/vps-tunnel-service.log"
depend() { need net; after firewall; }
RC
        chmod 755 /etc/init.d/vps-tunnel
        rc-update add "$SERVICE" default
    else
        cat > /etc/systemd/system/vps-tunnel.service <<'UNIT'
[Unit]
Description=Cloudflare Tunnel (VPS toolbox)
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/etc/vps-tunnel/run
Restart=always
RestartSec=5
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable "$SERVICE.service"
    fi
}
setup() {
    mode=$1
    confirm_replace || return 0
    if [ "$mode" = quick ]; then
        ask '请输入本地 HTTP / WebSocket 服务端口 [8080]：'
        port=${REPLY:-8080}
        case "$port" in ''|*[!0-9]*|??????*) die '端口必须是 1–65535。';; esac
        [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die '端口必须是 1–65535。'
        port=$(printf '%s' "$port" | sed 's/^0*//')
    else
        printf '请先在 Cloudflare 后台创建隧道，配置域名和本地服务地址。\n'
        ask '粘贴 Tunnel Token（只粘贴 Token，不要整条命令）：'
        token=$REPLY
        case "$token" in ''|*[!A-Za-z0-9_+/=-]*) die 'Token 为空或包含不允许的字符。';; esac
    fi
    [ -x "$BIN" ] || download
    if exists; then stop_if_running; fi
    umask 077
    mkdir -p "$BASE/home"
    chmod 700 "$BASE" "$BASE/home"
    printf '%s\n' "$mode" > "$BASE/mode"
    rm -f "$BASE/token" "$BASE/port"
    if [ "$mode" = quick ]; then printf '%s\n' "$port" > "$BASE/port"
    else printf '%s\n' "$token" > "$BASE/token"; unset token REPLY; fi
    mkdir -p /var/log/vps-tunnel
    : > "$LOG"
    write_runner
    write_service
    control start
    printf '已启用后台运行、进程退出自动重启、开机自启。\n'
    if [ "$mode" = quick ]; then
        printf '等待临时域名（最长 30 秒）…\n'
        count=0
        while [ "$count" -lt 15 ]; do
            if grep -Eq 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG"; then address; return; fi
            sleep 2
            count=$((count + 1))
        done
        printf '尚未获取域名；请选择“查看日志”检查连接。\n'
    else
        printf '固定域名请在 Cloudflare 后台查看；服务启动不等于隧道已连接。\n'
    fi
}
address() {
    if [ -f "$LOG" ]; then
        domain=$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG" | tail -n 1 || true)
        [ -z "$domain" ] || printf '本次运行的临时域名：%s\n' "$domain"
    fi
}
status() {
    exists || { printf '尚未安装本脚本管理的隧道。\n'; return; }
    printf '模式：%s\n' "$(cat "$BASE/mode")"
    control status || true
    if [ "$(cat "$BASE/mode")" = quick ]; then
        address
        printf '临时域名在重新启动后可能变化；停止时日志地址不可用。\n'
    else printf '固定域名及连接状态：请在 Cloudflare 后台查看。\n'; fi
}
logs() {
    [ ! -f "$LOG" ] || tail -n 80 "$LOG"
    if [ "$MANAGER" = systemd ]; then journalctl -u "$SERVICE.service" -n 30 --no-pager
    elif [ -f /var/log/vps-tunnel-service.log ]; then tail -n 30 /var/log/vps-tunnel-service.log; fi
}
stop_if_running() {
    if control status >/dev/null 2>&1; then control stop; fi
}
uninstall() {
    exists || { printf '尚未安装。\n'; return; }
    ask '卸载本脚本的隧道、配置和日志？输入 YES 确认：'
    [ "$REPLY" = YES ] || return 0
    stop_if_running
    if [ "$MANAGER" = openrc ]; then
        rc-update del "$SERVICE" default
        rm -f /etc/init.d/vps-tunnel
    else
        systemctl disable "$SERVICE.service"
        rm -f /etc/systemd/system/vps-tunnel.service
        systemctl daemon-reload
    fi
    rm -rf "$BASE" /usr/local/lib/vps-tunnel
    rm -rf /var/log/vps-tunnel
    rm -f /var/log/vps-tunnel-service.log
    printf '已卸载。Cloudflare 后台的隧道和 DNS 记录需自行删除。\n'
}
main() {
    detect
    while :; do
        printf '\nCloudflare 隧道管理 v%s | %s / %s\n' "$VERSION" "$ID" "$MANAGER"
        printf '1. 安装临时隧道（保活 + 开机自启）\n2. 安装固定隧道（保活 + 开机自启）\n3. 查看状态 / 临时域名\n4. 重启隧道\n5. 停止隧道\n6. 查看日志\n7. 卸载隧道\n0. 退出\n'
        ask '请选择：'
        case "$REPLY" in
            1) setup quick;; 2) setup fixed;; 3) status;;
            4) if exists; then control restart; else printf '尚未安装。\n'; fi;;
            5) if exists; then stop_if_running; else printf '尚未安装。\n'; fi;;
            6) logs;; 7) uninstall;; 0) exit 0;; *) printf '请输入正确选项。\n';;
        esac
    done
}
main "$@"
