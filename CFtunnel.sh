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
respawn_period=0
output_log="/var/log/vps-tunnel-service.log"
error_log="/var/log/vps-tunnel-service.log"
depend() { need net; after firewall; }
RC
        chmod 755 /etc/init.d/vps-tunnel
        rc-update add "$SERVICE" default
    else
