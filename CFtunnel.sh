#!/bin/sh
# Cloudflare Tunnel manager: Alpine/OpenRC and Debian/systemd
set -eu
VERSION=2.1.1
BASE=/etc/vps-tunnel
BIN=/usr/local/lib/vps-tunnel/cloudflared
SERVICE=vps-tunnel
LOG=/var/log/vps-tunnel/cloudflared.log
TMP=
NBASE=/etc/vps-node
NBIN=/usr/local/lib/vps-node/core
NSERVICE=vps-node
NLOG=/var/log/vps-node.log
RAW=https://raw.githubusercontent.com/Alsyok/argo/cores
SCREEN_ACTIVE=0
C_RESET= C_CYAN= C_GREEN= C_YELLOW= C_RED= C_DIM= C_WHITE=
if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$(printf '\033[0m')
    C_CYAN=$(printf '\033[1;36m')
    C_GREEN=$(printf '\033[1;32m')
    C_YELLOW=$(printf '\033[1;33m')
    C_RED=$(printf '\033[1;31m')
    C_DIM=$(printf '\033[90m')
    C_WHITE=$(printf '\033[1;37m')
fi
cleanup() { [ -z "$TMP" ] || rm -rf "$TMP"; }
trap 'cleanup; terminal_restore' EXIT
die() { printf '%s错误：%s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }
ask_form() { printf '\n' >&2; ask "$1"; }
ask() { printf '%s%s%s' "$C_YELLOW" "$1" "$C_RESET" >&2; IFS= read -r REPLY || exit 0; }
menu_item() { printf '  %s%3s%s  %s\n' "$1" "$2" "$C_RESET" "$3"; }
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
        apk add --no-cache curl ca-certificates jq tar unzip gcompat
    else
        apt-get update
        apt-get install -y curl ca-certificates jq tar unzip
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
export HOME="$BASE/home"
mode=$(cat "$BASE/mode")
protocol=$(cat "$BASE/protocol" 2>/dev/null || printf auto)
metrics=$(cat "$BASE/metrics-port")
run_core() {
    if [ "$mode" = quick ]; then
        rm -f "$BASE/domain-cache"
        : > /var/log/vps-tunnel/cloudflared.log
        port=$(cat "$BASE/port")
        exec "$BIN" tunnel --no-autoupdate --protocol "$1" --edge-ip-version auto --grace-period 2s --metrics "127.0.0.1:$metrics" --loglevel info --log-directory /var/log/vps-tunnel --url "http://127.0.0.1:$port"
    else
        exec "$BIN" tunnel --no-autoupdate --protocol "$1" --edge-ip-version auto --grace-period 2s --metrics "127.0.0.1:$metrics" --loglevel info --log-directory /var/log/vps-tunnel run --token-file "$BASE/token"
    fi
}
if [ "$protocol" != auto ]; then
    printf '%s\n' "$protocol" > "$BASE/effective-protocol"
    run_core "$protocol"
fi
# Automatic mode actively checks readiness; it does not rely solely on cloudflared's fallback.
active=$(cat "$BASE/effective-protocol" 2>/dev/null || printf quic)
case "$active" in quic|http2) :;; *) active=quic;; esac
CHILD=
stop_child() {
    if [ -n "$CHILD" ]; then
        kill "$CHILD" 2>/dev/null || true
        wait "$CHILD" 2>/dev/null || true
        CHILD=
    fi
}
trap 'stop_child; exit 0' INT TERM
trap stop_child EXIT
while :; do
    printf '%s\n' "$active" > "$BASE/effective-protocol"
    run_core "$active" &
    CHILD=$!
    failures=0
    while kill -0 "$CHILD" 2>/dev/null; do
        if curl --noproxy '*' -fsS --connect-timeout 1 --max-time 1 "http://127.0.0.1:$metrics/ready" >/dev/null 2>&1; then
            failures=0
        else
            failures=$((failures + 1))
        fi
        [ "$failures" -lt 10 ] || break
        sleep 2
    done
    stop_child
    if [ "$active" = quic ]; then active=http2; else active=quic; fi
    printf 'Automatic transport: retrying with %s\n' "$active" >&2
    sleep 2
done
RUN
    chmod 700 "$BASE/run"
    printf '%s\n' '2.1.0' > "$BASE/runner-version"
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
        read_port 8080
        read_path
    else
        printf '请先在 CF 后台配置域名 → http://127.0.0.1:本地端口。\n'
        read_domain
        read_port 8080
        read_path
        while :; do
            ask_form '粘贴 Tunnel Token（只粘贴 Token，不要整条命令）：'
            token=$REPLY
            case "$token" in
                ''|*[!A-Za-z0-9_+/=-]*) warn 'Token 为空或字符格式错误，请重新输入。';;
                *) break;;
            esac
        done
    fi
    read_protocol
    [ -x "$BIN" ] || download
    if exists; then stop_if_running; fi
    umask 077
    mkdir -p "$BASE/home"
    chmod 700 "$BASE" "$BASE/home"
    printf '%s\n' "$mode" > "$BASE/mode"
    rm -f "$BASE/token" "$BASE/domain"
    printf '%s\n' "$ws_path" > "$BASE/ws-path"
    rm -f "$BASE/effective-protocol"
    printf '%s\n' "$protocol" > "$BASE/protocol"
    printf '%s\n' "$port" > "$BASE/port"
    choose_metrics
    if [ "$mode" = quick ]; then printf '%s\n' "$port" > "$BASE/port"
    else printf '%s\n' "$token" > "$BASE/token"; printf '%s\n' "$domain" > "$BASE/domain"; unset token REPLY; fi
    mkdir -p /var/log/vps-tunnel
    : > "$LOG"
    write_runner
    write_service
    control start
    printf '已启用后台运行、进程退出自动重启、开机自启。\n'
    if wait_connected; then
        good '隧道已连接 Cloudflare。'
        address
        ask '继续安装节点？1 sing-box / 2 Xray / 0 暂不安装：'
        case "$REPLY" in 1) install_node sing-box;; 2) install_node xray;; *) :;; esac
    else
        warn '暂未确认连接，请查看日志；禁 UDP 的服务器可在菜单 15 切换 HTTP/2。'
    fi
}
address() {
    if current_domain; then printf '隧道域名：%s\n' "$domain"; fi
}
status() {
    exists || { printf '尚未安装本脚本管理的隧道。\n'; return; }
    printf '模式：%s\n' "$(cat "$BASE/mode")"
    control status || true
    if [ "$(cat "$BASE/mode")" = quick ]; then
        address
        printf '临时域名在重新启动后可能变化；停止时日志地址不可用。\n'
    else address; fi
    if connected; then good '已连接 Cloudflare。'; else warn '连接尚未确认。'; fi
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

good() { printf '%s  ✓ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%s  ! %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
rule() { printf '%s  ──────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"; }
read_port() {
    while :; do
        ask_form "本地 WS 端口 [$1]："
        port=${REPLY:-$1}
        case "$port" in ''|*[!0-9]*|??????*) warn '请输入 1–65535。'; continue;; esac
        port=$(printf '%s' "$port" | sed 's/^0*//'); port=${port:-0}
        if [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then return; fi
        warn '请输入 1–65535。'
    done
}
valid_domain() {
    [ "${#1}" -le 253 ] && printf '%s\n' "$1" | grep -Eq '^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'
}
read_domain() {
    while :; do
        ask_form '固定隧道域名（不含 https:// 和路径）：'
        domain=$REPLY
        if valid_domain "$domain"; then return; fi
        warn '请输入完整域名，例如 node.example.com。'
    done
}
read_path() {
    while :; do
        ask_form '本地 WebSocket 路径 [/argo]：'
        ws_path=${REPLY:-/argo}
        if [ "${#ws_path}" -le 128 ] && printf '%s\n' "$ws_path" | grep -Eq '^/[A-Za-z0-9/._~-]*$'; then return; fi
        warn '路径需以 / 开头，使用字母、数字或 / . _ ~ -，请重新输入。'
    done
}
read_protocol() {
    while :; do
        ask_form '隧道传输：1 自动 / 2 HTTP2（禁 UDP 时选） / 3 QUIC [1]：'
        case "${REPLY:-1}" in 1) protocol=auto; return;; 2) protocol=http2; return;; 3) protocol=quic; return;; *) warn '请输入 1、2 或 3。';; esac
    done
}
port_busy() {
    target_hex=$(printf '%04X' "$1")
    awk -v p="$target_hex" '$4 == "0A" {split($2,a,":"); if (toupper(a[length(a)]) == p) found=1} END {exit !found}' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}
choose_metrics() {
    # Retain the existing port; otherwise select an unused local port.
    if [ -s "$BASE/metrics-port" ] && [ "$(cat "$BASE/metrics-port")" != "$port" ]; then return; fi
    metrics=20241
    while port_busy "$metrics" || [ "$metrics" = "$port" ]; do
        metrics=$((metrics + 1))
        [ "$metrics" -le 20260 ] || die '找不到可用的本地监控端口。'
    done
    printf '%s\n' "$metrics" > "$BASE/metrics-port"
}
connected() {
    control status >/dev/null 2>&1 || return 1
    [ -s "$BASE/metrics-port" ] || return 1
    curl --noproxy '*' -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:$(cat "$BASE/metrics-port")/ready" >/dev/null 2>&1
}
wait_connected() {
    printf '  正在确认 Cloudflare 连接（自动模式会切换传输，最长约 90 秒）…\n'
    count=0
    while [ "$count" -lt 30 ]; do
        if connected; then return; fi
        sleep 1; count=$((count + 1))
    done
    return 1
}
prepare_tunnel() {
    exists || die '请先安装隧道。'
    mode=$(cat "$BASE/mode")
    case "$mode" in quick|fixed) :;; *) die '未知隧道模式。';; esac
    if [ ! -s "$BASE/port" ]; then
        read_port 8080; printf '%s\n' "$port" > "$BASE/port"
    else port=$(cat "$BASE/port"); fi
    if [ "$mode" = fixed ] && [ ! -s "$BASE/domain" ]; then
        read_domain; printf '%s\n' "$domain" > "$BASE/domain"
        warn "请确认 CF 后台的服务地址为 http://127.0.0.1:$port。"
    fi
    if [ ! -s "$BASE/protocol" ]; then
        protocol=auto
        if grep -q -- '--protocol http2' "$BASE/run"; then protocol=http2; fi
        if grep -q -- '--protocol quic' "$BASE/run"; then protocol=quic; fi
        printf '%s\n' "$protocol" > "$BASE/protocol"
    fi
    if [ ! -s "$BASE/metrics-port" ] || [ "$(cat "$BASE/runner-version" 2>/dev/null || true)" != '2.1.0' ]; then
        choose_metrics
        write_runner
        control restart
    fi
    connected || wait_connected || die '隧道尚未连接，请先查看日志或切换传输。'
}
set_transport() {
    exists || die '尚未安装隧道。'
    read_protocol
    rm -f "$BASE/effective-protocol"
    printf '%s\n' "$protocol" > "$BASE/protocol"
    port=$(cat "$BASE/port" 2>/dev/null || printf 8080)
    choose_metrics
    write_runner
    control restart
    if wait_connected; then good '隧道已连接。'; address; else warn '尚未连接，请查看日志。'; fi
}
node_exists() { [ -s "$NBASE/core" ] && [ -x "$NBIN" ]; }
node_control() {
    if [ "$MANAGER" = openrc ]; then rc-service "$NSERVICE" "$1"
    else systemctl "$1" "$NSERVICE.service"; fi
}
node_stop() { if node_control status >/dev/null 2>&1; then node_control stop; fi; }
node_service() {
    cat > "$NBASE/run" <<'NODE'
#!/bin/sh
set -eu
cd /etc/vps-node
case "$(cat core)" in
    sing-box) exec /usr/local/lib/vps-node/core run -c /etc/vps-node/config.json;;
    xray) exec /usr/local/lib/vps-node/core run -config /etc/vps-node/config.json;;
    *) exit 1;;
esac
NODE
    chmod 700 "$NBASE/run"
    if [ "$MANAGER" = openrc ]; then
        cat > /etc/init.d/vps-node <<'RC'
#!/sbin/openrc-run
name="VLESS WebSocket node"
supervisor="supervise-daemon"
command="/etc/vps-node/run"
respawn_delay=5
respawn_max=0
respawn_period=60
output_log="/var/log/vps-node.log"
error_log="/var/log/vps-node.log"
depend() { need net; after firewall; }
RC
        chmod 755 /etc/init.d/vps-node
        rc-update add "$NSERVICE" default
    else
        cat > /etc/systemd/system/vps-node.service <<'UNIT'
[Unit]
Description=VLESS WebSocket node
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStart=/etc/vps-node/run
Restart=always
RestartSec=5
UMask=0077
[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable "$NSERVICE.service"
    fi
}
fetch_core() {
    curl -fLsS --retry 3 --connect-timeout 15 --max-time 60 "$RAW/manifest.json?t=$(date +%s)" -o "$TMP/manifest.json"
    jq -e '.schema_version == 2 and .distribution == "github-raw"' "$TMP/manifest.json" >/dev/null || die 'Raw 版本清单格式错误，请确认工作流已经成功。'
    asset_url=$(jq -er --arg c "$core" --arg a "$ARCH" '.cores[$c].assets[$a].download_url' "$TMP/manifest.json")
    digest=$(jq -er --arg c "$core" --arg a "$ARCH" '.cores[$c].assets[$a].sha256' "$TMP/manifest.json")
    core_version=$(jq -er --arg c "$core" '.cores[$c].version' "$TMP/manifest.json")
    case "$asset_url" in "$RAW"/versions/*) :;; *) die '安装包地址不属于你的 Raw 仓库。';; esac
    printf '%s' "$digest" | grep -Eq '^[a-f0-9]{64}$' || die '校验值格式错误。'
    good "下载 $core $core_version / $ARCH"
    curl -fL --retry 3 --connect-timeout 15 --max-time 300 "$asset_url" -o "$TMP/archive"
    printf '%s  %s\n' "$digest" "$TMP/archive" | sha256sum -c - || die '安装包校验失败。'
    if [ "$core" = sing-box ]; then
        member=$(tar -tzf "$TMP/archive" | awk '/(^|\/)sing-box$/ {print}')
        [ "$(printf '%s\n' "$member" | wc -l)" -eq 1 ] && [ -n "$member" ] || die '安装包结构错误。'
        tar -xOzf "$TMP/archive" "$member" > "$TMP/core"
    else
        unzip -p "$TMP/archive" xray > "$TMP/core"
    fi
    chmod 755 "$TMP/core"
    "$TMP/core" version
}
build_config() {
    if [ "$core" = sing-box ]; then
        jq -n --arg uuid "$uuid" --arg path "$ws_path" --argjson port "$port" '{log:{level:"info",timestamp:true},inbounds:[{type:"vless",tag:"vless-ws",listen:"127.0.0.1",listen_port:$port,users:[{uuid:$uuid}],transport:{type:"ws",path:$path}}],outbounds:[{type:"direct",tag:"direct"}]}' > "$TMP/config.json"
        "$TMP/core" check -c "$TMP/config.json"
    else
        jq -n --arg uuid "$uuid" --arg path "$ws_path" --argjson port "$port" '{log:{loglevel:"warning"},inbounds:[{tag:"vless-ws",listen:"127.0.0.1",port:$port,protocol:"vless",settings:{clients:[{id:$uuid}],decryption:"none"},streamSettings:{network:"ws",security:"none",wsSettings:{path:$path}}}],outbounds:[{protocol:"freedom",tag:"direct"}]}' > "$TMP/config.json"
        "$TMP/core" run -test -config "$TMP/config.json"
    fi
}
rollback_node() {
    if [ "${deploying:-0}" = 1 ]; then
        warn '部署未完成，正在恢复原节点。'
        node_stop || true
        rm -rf "$NBASE"
        rm -f "$NBIN"
        if [ -d "$TMP/old-node" ]; then
            cp -a "$TMP/old-node" "$NBASE"
            cp "$TMP/old-core" "$NBIN"; chmod 755 "$NBIN"
            if [ "$was_running" = 1 ]; then node_control start || true; fi
        else
            if [ "$MANAGER" = openrc ]; then
                rc-update del "$NSERVICE" default >/dev/null 2>&1 || true
                rm -f /etc/init.d/vps-node
            else
                systemctl disable "$NSERVICE.service" >/dev/null 2>&1 || true
                rm -f /etc/systemd/system/vps-node.service
                systemctl daemon-reload
            fi
        fi
    fi
    cleanup
}
install_node() {
    core=$1
    if node_exists; then
        ask '已有节点。继续安装 / 切换并保留 UUID 和 WS 路径？输入 YES：'
        [ "$REPLY" = YES ] || return 0
    fi
    dependencies
    prepare_tunnel
    if port_busy "$port" && ! node_control status >/dev/null 2>&1; then
        die "端口 $port 被其他程序占用，请先处理；本脚本不会停止其他服务。"
    fi
    TMP=$(mktemp -d)
    deploying=0; was_running=0
    trap rollback_node EXIT
    fetch_core
    if node_exists; then
        uuid=$(cat "$NBASE/uuid"); ws_path=$(cat "$NBASE/path")
        cp -a "$NBASE" "$TMP/old-node"; cp "$NBIN" "$TMP/old-core"
        if node_control status >/dev/null 2>&1; then was_running=1; fi
    else
        uuid=$(cat /proc/sys/kernel/random/uuid)
        ws_path="/argo-$(printf '%s' "$uuid" | cut -c 1-8)"
    fi
    if [ -s "$BASE/ws-path" ]; then ws_path=$(cat "$BASE/ws-path"); fi
    build_config
    deploying=1
    if node_exists; then node_stop; fi
    port_busy "$port" && die "端口 $port 仍被占用，已取消部署。"
    umask 077
    mkdir -p "$NBASE" /usr/local/lib/vps-node
    chmod 700 "$NBASE" /usr/local/lib/vps-node
    cp "$TMP/core" "$NBIN"; chmod 755 "$NBIN"
    cp "$TMP/config.json" "$NBASE/config.json"
    printf '%s\n' "$core" > "$NBASE/core"
    printf '%s\n' "$core_version" > "$NBASE/version"
    printf '%s\n' "$port" > "$NBASE/port"
    printf '%s\n' "$uuid" > "$NBASE/uuid"
    printf '%s\n' "$ws_path" > "$NBASE/path"
    node_service
    node_control start
    count=0
    while [ "$count" -lt 10 ]; do
        if node_control status >/dev/null 2>&1 && port_busy "$port"; then break; fi
        sleep 1; count=$((count + 1))
    done
    [ "$count" -lt 10 ] || die '节点未成功监听，请检查日志。'
    deploying=0
    good '节点已启动，保活和开机自启已启用。'
    node_info
}
node_menu() {
    printf '\n%s  选择节点核心%s\n' "$C_CYAN" "$C_RESET"; rule
    menu_item "$C_GREEN" '1.' 'sing-box'
    menu_item "$C_GREEN" '2.' 'Xray'
    menu_item "$C_DIM" '0.' '返回'
    while :; do
        ask '请选择 [0–2]：'
        case "$REPLY" in 1) install_node sing-box; return;; 2) install_node xray; return;; 0) return;; *) warn '请选择 0、1 或 2。';; esac
    done
}
current_domain() {
    [ -s "$BASE/mode" ] || return 1
    if [ "$(cat "$BASE/mode")" = fixed ]; then
        [ -s "$BASE/domain" ] || return 1
        domain=$(cat "$BASE/domain")
    else
        control status >/dev/null 2>&1 || return 1
        domain=$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG" 2>/dev/null | tail -n 1 || true)
        domain=${domain#https://}
        if [ -n "$domain" ]; then
            (umask 077; printf '%s\n' "$domain" > "$BASE/domain-cache")
        elif [ -s "$BASE/domain-cache" ]; then domain=$(cat "$BASE/domain-cache"); fi
    fi
    valid_domain "$domain"
}
node_info() {
    node_exists || die '尚未安装节点核心。'
    command -v jq >/dev/null || dependencies
    core=$(cat "$NBASE/core"); uuid=$(cat "$NBASE/uuid")
    ws_path=$(cat "$NBASE/path"); port=$(cat "$NBASE/port")
    if ! current_domain; then
        warn '当前域名无法获取；上次保存的信息仅供参考。'
        [ ! -s "$NBASE/node-info.txt" ] || cat "$NBASE/node-info.txt"
        return 0
    fi
    locate_country
    case "$core" in sing-box) node_label="Argo-singbox-$country_flag";; *) node_label="Argo-Xray-$country_flag";; esac
    label_encoded=$(jq -nr --arg s "$node_label" '$s|@uri')
    path_encoded=$(jq -nr --arg s "$ws_path" '$s|@uri')
    link="vless://$uuid@$domain:443?encryption=none&security=tls&sni=$domain&type=ws&host=$domain&path=$path_encoded#$label_encoded"
    umask 077
    {
        printf '节点名称：%s\n出口地区：%s\n\n' "$node_label" "$country_name"
        printf '核心：%s %s\n' "$core" "$(cat "$NBASE/version")"
        printf '域名：%s\n客户端端口：443\n本地监听：127.0.0.1:%s\n' "$domain" "$port"
        printf '协议：VLESS\nUUID：%s\n传输：WebSocket\nWS 路径：%s\n' "$uuid" "$ws_path"
        printf '客户端 TLS：开启\nSNI / WS Host：%s\n本地 TLS：关闭\n\n%s\n' "$domain" "$link"
    } > "$NBASE/node-info.txt.new"
    mv "$NBASE/node-info.txt.new" "$NBASE/node-info.txt"
    printf '%s\n' "$link" > "$NBASE/node-link.txt"
    rule; printf '%s  NODE · 节点信息%s\n' "$C_CYAN" "$C_RESET"; rule
    cat "$NBASE/node-info.txt"
    rule
    good "已保存至 $NBASE/node-info.txt"
    connection_report
    if [ -s "$BASE/port" ] && [ "$(cat "$BASE/port")" != "$port" ]; then
        warn '隧道端口与节点监听端口不一致，请重新配置节点。'
    fi
    if [ "$(cat "$BASE/mode")" = quick ]; then warn '临时域名变化后请重新查询并更新客户端。'; fi
}
node_logs() {
    if [ "$MANAGER" = systemd ]; then journalctl -u "$NSERVICE.service" -n 60 --no-pager
    elif [ -f "$NLOG" ]; then tail -n 60 "$NLOG"
    else warn '暂无节点日志。'; fi
}
locate_country() {
    country_flag=🌐; country_name=未知
    # Geolocation of this VPS's egress IP; failure never blocks node installation.
    geo=$(curl -fsS --connect-timeout 2 --max-time 4 https://ipapi.co/json/ 2>/dev/null || true)
    code=$(printf '%s' "$geo" | jq -er '.country_code // empty' 2>/dev/null || true)
    if printf '%s' "$code" | grep -Eq '^[A-Z]{2}$'; then
        country_flag=$(jq -nr --arg c "$code" '$c|explode|map(.+127397)|implode')
        country_name=$(printf '%s' "$geo" | jq -r '.country_name // "未知"')
        (umask 077; printf '%s\n' "$code" > "$NBASE/country-code"; printf '%s\n' "$country_name" > "$NBASE/country-name")
    elif [ -s "$NBASE/country-code" ]; then
        code=$(cat "$NBASE/country-code")
        if printf '%s' "$code" | grep -Eq '^[A-Z]{2}$'; then
            country_flag=$(jq -nr --arg c "$code" '$c|explode|map(.+127397)|implode')
            country_name=$(cat "$NBASE/country-name" 2>/dev/null || printf 未知)
        fi
    fi
}
connection_report() {
    printf '\n'; rule
    if connected; then good '隧道：已连接 Cloudflare'; else warn '隧道：未确认连接'; fi
    if node_control status >/dev/null 2>&1 && port_busy "$port"; then
        good "节点：运行中，监听 127.0.0.1:$port"
        # Verify TLS and the end-to-end WebSocket upgrade, without claiming a VLESS traffic test.
        check_headers=$(mktemp)
        curl --noproxy '*' -sS --http1.1 --connect-timeout 3 --max-time 5 \
            -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
            -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
            -D "$check_headers" -o /dev/null "https://$domain$ws_path" 2>/dev/null || true
        if grep -Eq '^HTTP/[^ ]+ 101([[:space:]]|$)' "$check_headers"; then
            good 'WS 链路：TLS → CF 隧道 → 节点握手成功'
        else
            warn 'WS 链路：尚未验证成功，请检查 CF 域名、端口和路径。'
        fi
        rm -f "$check_headers"
    else warn '节点：未运行或未监听'; fi
    printf '%s  VLESS 实际代理流量请在客户端测试。%s\n' "$C_DIM" "$C_RESET"
    rule
}
terminal_enter() {
    if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then
        printf '\033[?1049h\033[2J\033[H'
        SCREEN_ACTIVE=1
        trap 'exit 130' INT
        trap 'exit 143' TERM
    fi
}
terminal_restore() {
    if [ "$SCREEN_ACTIVE" = 1 ]; then printf '\033[?1049l'; fi
}
clear_screen() {
    if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then printf '\033[2J\033[H'; fi
}
finish_screen() {
    printf '\n'
    menu_item "$C_CYAN" '1.' '返回首页'
    menu_item "$C_DIM" '0.' '退出脚本'
    while :; do
        ask '请选择 [0–1]：'
        case "$REPLY" in 1) return;; 0) exit 0;; *) warn '请输入 0 或 1。';; esac
    done
}
update_node() {
    node_exists || die '尚未安装节点。'
    install_node "$(cat "$NBASE/core")"
}
remove_node() {
    node_exists || die '尚未安装节点。'
    ask '删除节点核心、配置和保存的节点信息？输入 YES：'
    [ "$REPLY" = YES ] || return 0
    node_stop
    if [ "$MANAGER" = openrc ]; then
        rc-update del "$NSERVICE" default
        rm -f /etc/init.d/vps-node
    else
        systemctl disable "$NSERVICE.service"
        rm -f /etc/systemd/system/vps-node.service
        systemctl daemon-reload
    fi
    rm -rf "$NBASE" /usr/local/lib/vps-node
    rm -f "$NLOG"
    good '节点核心已卸载。'
}
header() {
    printf '%s  ARGO · 隧道与节点管理%s\n' "$C_CYAN" "$C_RESET"; rule
    printf '  系统  %s%s%s / %s  ·  v%s\n' "$C_WHITE" "$ID" "$C_RESET" "$MANAGER" "$VERSION"
    if exists; then
        case "$(cat "$BASE/mode")" in quick) label=临时隧道;; *) label=固定隧道;; esac
        if connected; then state=已连接; color=$C_GREEN
        elif control status >/dev/null 2>&1; then state='运行中 · 连接待确认'; color=$C_YELLOW
        else state=已停止; color=$C_DIM; fi
        printf '  隧道  %s · %s%s%s\n' "$label" "$color" "$state" "$C_RESET"
    else printf '  隧道  %s未安装%s\n' "$C_DIM" "$C_RESET"; fi
    if node_exists; then
        if node_control status >/dev/null 2>&1; then state=运行中; color=$C_GREEN; else state=已停止; color=$C_DIM; fi
        printf '  核心  %s · %s%s%s\n' "$(cat "$NBASE/core")" "$color" "$state" "$C_RESET"
    else printf '  核心  %s未安装%s\n' "$C_DIM" "$C_RESET"; fi
    rule
}
run_action() {
    # Keep operational failures inside a subshell, allowing return to the menu.
    set +e
    (set -eu; trap cleanup EXIT; "$@")
    action_result=$?
    set -e
    if [ "$action_result" -ne 0 ]; then warn '操作未完成，请查看上面的错误提示。'; fi
}
main() {
    detect
    terminal_enter
    clear_screen
    while :; do
        header
        printf '\n%s  TUNNEL / 隧道管理%s\n' "$C_CYAN" "$C_RESET"
        menu_item "$C_GREEN" '1.' '安装临时隧道（保活 + 开机自启）'
        menu_item "$C_GREEN" '2.' '安装固定隧道（保活 + 开机自启）'
        menu_item "$C_CYAN" '3.' '查看隧道状态 / 域名'
        menu_item "$C_YELLOW" '4.' '重启隧道'
        menu_item "$C_YELLOW" '5.' '停止隧道'
        menu_item "$C_CYAN" '6.' '查看隧道日志'
        menu_item "$C_RED" '7.' '卸载隧道'
        printf '\n%s  NODE / 节点管理%s\n' "$C_CYAN" "$C_RESET"
        menu_item "$C_GREEN" '8.' '安装 / 切换节点核心'
        menu_item "$C_CYAN" '9.' '查询节点信息 / 分享链接'
        menu_item "$C_YELLOW" '10.' '重启节点'
        menu_item "$C_YELLOW" '11.' '停止节点'
        menu_item "$C_CYAN" '12.' '查看节点日志'
        menu_item "$C_GREEN" '13.' '更新节点核心'
        menu_item "$C_RED" '14.' '卸载节点核心'
        printf '\n%s  NETWORK / 网络设置%s\n' "$C_CYAN" "$C_RESET"
        menu_item "$C_YELLOW" '15.' '隧道传输（自动 / HTTP2 / QUIC）'
        menu_item "$C_DIM" '0.' '退出'
        rule
        while :; do
            ask '  请选择 [0–15]：'
            case "$REPLY" in 0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15) break;; *) warn '请输入 0–15，重新选择即可。';; esac
        done
        case "$REPLY" in
            1) run_action setup quick;; 2) run_action setup fixed;; 3) run_action status;;
            4) if exists; then run_action control restart; else warn '尚未安装。'; fi;;
            5) run_action stop_if_running;; 6) run_action logs;; 7) run_action uninstall;;
            8) run_action node_menu;; 9) run_action node_info;;
            10) if node_exists; then run_action node_control restart; else warn '尚未安装节点。'; fi;;
            11) if node_exists; then run_action node_stop; else warn '尚未安装节点。'; fi;;
            12) run_action node_logs;; 13) run_action update_node;; 14) run_action remove_node;;
            15) run_action set_transport;; 0) exit 0;; *) warn '请输入正确选项。';;
        esac
        finish_screen
        clear_screen
    done
}
main "$@"
