#!/bin/sh
# Cloudflare Tunnel manager: Alpine/OpenRC and Debian/systemd
set -eu
VERSION=2.4.9
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
C_STATUS_LINE= C_ERROR= C_WARNING= C_RETRY= C_LINE= C_LINK= C_INSTALL= C_PROMPT= C_BLUE= C_PURPLE= C_RESET= C_CYAN= C_GREEN= C_YELLOW= C_RED= C_DIM= C_WHITE=
if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$(printf '\033[0m')
    C_CYAN=$(printf '\033[38;2;129;206;214m')
    C_BLUE=$(printf '\033[38;2;136;179;223m')
    C_PURPLE=$(printf '\033[38;2;181;161;223m')
    C_GREEN=$(printf '\033[38;2;151;203;168m')
    C_YELLOW=$(printf '\033[38;2;223;197;138m')
    C_RED=$(printf '\033[38;2;225;155;155m')
    C_DIM=$(printf '\033[38;2;164;175;190m')
    C_WHITE=$(printf '\033[38;2;220;227;235m')
    C_ERROR=$(printf '\033[38;2;255;85;85m')
    C_WARNING=$(printf '\033[38;2;229;192;123m')
    C_RETRY=$(printf '\033[38;2;192;132;252m')
    C_LINE=$(printf '\033[38;2;82;103;124m')
    C_STATUS_LINE=$(printf '\033[38;2;97;175;239m')
    C_LINK=$(printf '\033[38;2;255;250;205m')
    C_INSTALL=$(printf '\033[38;2;144;238;144m')
    C_PROMPT=$(printf '\033[38;2;154;205;50m')
fi
cleanup() { [ -z "$TMP" ] || rm -rf "$TMP"; }
trap 'cleanup; terminal_restore' EXIT
die() { printf '  %s错误：%s%s\n' "$C_ERROR" "$*" "$C_RESET" >&2; exit 1; }
ask_form() { printf '\n' >&2; ask "$1"; }
print_prompt_defaults() {
    prompt_rest=$1
    prompt_color=${2:-$C_CYAN}
    printf '%s' "$prompt_color" >&2
    while :; do
        case "$prompt_rest" in
            *'['*']'*)
                prompt_before=${prompt_rest%%\[*}
                prompt_after=${prompt_rest#*\[}
                prompt_default=${prompt_after%%\]*}
                printf '%s%s[%s]%s' "$prompt_before" "$C_PURPLE" "$prompt_default" "$prompt_color" >&2
                prompt_rest=${prompt_after#*\]};;
            *) printf '%s%s' "$prompt_rest" "$C_RESET" >&2; break;;
        esac
    done
}
ask() {
    ask_base_color=$C_CYAN
    case "${1#  }" in
        '请选择 [0–18]：'|'已有本脚本管理的隧道。替换配置？'*|'本地 WS 端口 '*|'本地 WebSocket 路径 '*) ask_base_color=$C_PROMPT;;
    esac
    case "$1" in
        *'输入 “YES/y” 继续，“NO/n” 取消：'*)
            ask_prefix=${1%%输入 “YES/y” 继续，“NO/n” 取消：*}
            printf '  %s%s%s%s%s' "$ask_base_color" "${ask_prefix#  }" "$C_PURPLE" '输入 “YES/y” 继续，“NO/n” 取消：' "$C_RESET" >&2;;
        *) printf '  ' >&2; print_prompt_defaults "${1#  }" "$ask_base_color";;
    esac
    IFS= read -r REPLY || exit 0
    REPLY=$(printf '%s' "$REPLY" | tr -d '\r')
}
menu_item() { printf '  %s%3s%s  %s%s%s\n' "$C_WHITE" "$2" "$C_RESET" "$1" "$3" "$C_RESET"; }
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
        ask '已有本脚本管理的隧道。替换配置？输入 “YES/y” 继续，“NO/n” 取消：'
        confirmed || return 1
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
        printf '%s  请先在 CF 后台 → 配置域名 → http://127.0.0.1:本地端口。%s\n' "$C_ERROR" "$C_RESET"
        read_domain
        read_port 8080
        read_path
        while :; do
            ask_form '粘贴 Tunnel Token（只粘贴 Token，不要整条命令）：'
            token=$REPLY
            case "$token" in
                ''|*[!A-Za-z0-9_+/=-]*) retry_input 'Token 为空或字符格式错误，请重新输入。';;
                *) break;;
            esac
        done
    fi
    read_protocol
    [ -x "$BIN" ] || download
    sync_disable
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
    ask '卸载本脚本的隧道、配置和日志？输入 “YES/y” 继续，“NO/n” 取消：'
    confirmed || return 0
    sync_remove
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

confirmed() {
    while :; do
        confirm_reply=$(printf '%s' "$REPLY" | tr -d ' \t\r' | tr 'a-z' 'A-Z')
        case "$confirm_reply" in
            YES|Y) return 0;;
            NO|N) return 1;;
            *) retry_input '请输入 “YES/y” 继续，或 “NO/n” 取消。'
               ask '输入 “YES/y” 继续，“NO/n” 取消：';;
        esac
    done
}
good() { printf '%s  ✓ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%s  ⚠ %s%s\n' "$C_WARNING" "$*" "$C_RESET" >&2; }
retry_input() { printf '%s  ↻ %s%s\n' "$C_RETRY" "$*" "$C_RESET" >&2; }
rule() { printf '%s  ──────────────────────────────────────────%s\n' "$C_LINE" "$C_RESET"; }
status_rule() {
    printf '%s  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄\n  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄%s\n' "$C_STATUS_LINE" "$C_RESET"
}
read_port() {
    while :; do
        ask_form "本地 WS 端口 [$1]："
        port=${REPLY:-$1}
        case "$port" in ''|*[!0-9]*|??????*) retry_input '请输入 1–65535。'; continue;; esac
        port=$(printf '%s' "$port" | sed 's/^0*//'); port=${port:-0}
        if [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then return; fi
        retry_input '请输入 1–65535。'
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
        retry_input '请输入完整域名，例如 node.example.com。'
    done
}
read_path() {
    while :; do
        ask_form "本地 WebSocket 路径 [${path_default:-/argo}]："
        ws_path=${REPLY:-${path_default:-/argo}}
        if [ "${#ws_path}" -le 128 ] && printf '%s\n' "$ws_path" | grep -Eq '^/[A-Za-z0-9/._~-]*$'; then return; fi
        retry_input '路径需以 / 开头，使用字母、数字或 / . _ ~ -，请重新输入。'
    done
}
read_protocol() {
    while :; do
        ask_form '隧道传输：1 自动 / 2 HTTP2（禁 UDP 时选） / 3 QUIC [1]：'
        case "${REPLY:-1}" in 1) protocol=auto; return;; 2) protocol=http2; return;; 3) protocol=quic; return;; *) retry_input '请输入 1、2 或 3。';; esac
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
    if [ "$MANAGER" = openrc ]; then
        rc-service "$NSERVICE" "$1" || return $?
    else systemctl "$1" "$NSERVICE.service" || return $?; fi
    case "$1" in start|restart) sync_stamp;; esac
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
    edit_node=0
    if node_exists; then
        printf '\n'
        menu_item "$C_GREEN" '1.' '保留 UUID、WS 路径和端口'
        menu_item "$C_YELLOW" '2.' '修改 UUID、WS 路径和端口（留空沿用）'
        menu_item "$C_DIM" '0.' '取消'
        while :; do
            ask '请选择 [0–2]：'
            case "$REPLY" in 1) break;; 2) edit_node=1; break;; 0) return;; *) retry_input '请输入 0、1 或 2。';; esac
        done
    fi
    dependencies
    prepare_tunnel
    if node_exists; then
        uuid=$(cat "$NBASE/uuid"); ws_path=$(cat "$NBASE/path"); port=$(cat "$NBASE/port")
        if [ "$edit_node" = 1 ]; then
            original_uuid=$uuid
            while :; do
                ask_form "UUID [$original_uuid]："
                uuid=${REPLY:-$original_uuid}
                if printf '%s\n' "$uuid" | grep -Eq '^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$'; then break; fi
                retry_input 'UUID 格式错误，请重新输入。'
            done
            path_default=$ws_path
            read_path
            read_port "$port"
        fi
    else
        uuid=$(cat /proc/sys/kernel/random/uuid)
        ws_path=$(cat "$BASE/ws-path" 2>/dev/null || printf '/argo')
    fi
    if port_busy "$port" && ! node_control status >/dev/null 2>&1; then
        die "端口 $port 被其他程序占用，请先处理；本脚本不会停止其他服务。"
    fi
    TMP=$(mktemp -d)
    deploying=0; was_running=0
    trap rollback_node EXIT
    fetch_core
    if node_exists; then
        cp -a "$NBASE" "$TMP/old-node"; cp "$NBIN" "$TMP/old-core"
        if node_control status >/dev/null 2>&1; then was_running=1; fi
    fi
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
    previous_port=$(cat "$BASE/port")
    printf '%s\n' "$port" > "$BASE/port"
    printf '%s\n' "$ws_path" > "$BASE/ws-path"
    if [ "$previous_port" != "$port" ]; then
        if [ "$(cat "$BASE/mode")" = quick ]; then
            control restart
            if ! wait_connected; then warn '节点端口已更新，但隧道连接尚未恢复。'; fi
        else
            warn "请在 CF 后台把服务地址改为 http://127.0.0.1:$port。"
        fi
    fi
    good '节点已启动，保活和开机自启已启用。'
    sync_stamp
    node_info
    sync_install
}
node_menu() {
    printf '\n%s  选择节点核心%s\n' "$C_CYAN" "$C_RESET"; rule
    menu_item "$C_GREEN" '1.' 'sing-box'
    menu_item "$C_GREEN" '2.' 'Xray'
    menu_item "$C_DIM" '0.' '返回'
    while :; do
        ask '请选择 [0–2]：'
        case "$REPLY" in 1) install_node sing-box; return;; 2) install_node xray; return;; 0) return;; *) retry_input '请选择 0、1 或 2。';; esac
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
print_node_info() {
    while IFS= read -r info_line || [ -n "$info_line" ]; do
        info_color=
        case "$info_line" in
            域名：*|'SNI / WS Host：'*) info_color=$C_CYAN;;
            UUID：*) info_color=$C_PURPLE;;
            'WS 路径：'*) info_color=$C_YELLOW;;
            vless://*) info_color=$C_LINK;;
        esac
        printf '%s%s%s\n' "$info_color" "$info_line" "$C_RESET"
    done < "$NBASE/node-info.txt"
}
node_info() {
    node_exists || die '尚未安装节点核心。'
    if [ -x "$SYNCBIN" ] && [ "${api_local_changed:-0}" != 1 ]; then
        if ! "$SYNCBIN" --once foreground; then
            warn '自动同步未完成，保留上次有效节点信息。'
            [ ! -s "$NBASE/node-info.txt" ] || print_node_info
            return 0
        fi
    fi
    command -v jq >/dev/null || dependencies
    core=$(cat "$NBASE/core"); uuid=$(cat "$NBASE/uuid")
    ws_path=$(cat "$NBASE/path"); port=$(cat "$NBASE/port")
    if ! current_domain; then
        warn '当前域名无法获取；上次保存的信息仅供参考。'
        [ ! -s "$NBASE/node-info.txt" ] || print_node_info
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
    rule; printf '%s  NODE · 节点信息%s\n' "$C_PURPLE" "$C_RESET"; rule
    print_node_info
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
    # Query this VPS directly, with bounded retries across providers and IP families.
    code=; geo=
    for family in -4 -6; do
        for endpoint in https://ipapi.co/json/ https://api.ip.sb/geoip https://ipwho.is/; do
            geo=$(curl "$family" --noproxy '*' -fsS --connect-timeout 2 --max-time 4 "$endpoint" 2>/dev/null || true)
            code=$(printf '%s' "$geo" | jq -er '
                select(type == "object" and .success != false and .error != true)
                | .country_code | select(type == "string") | ascii_upcase
                | select(test("^[A-Z]{2}$") and . != "XX" and . != "ZZ")
            ' 2>/dev/null || true)
            [ -n "$code" ] && break
        done
        [ -n "$code" ] && break
    done
    if [ -n "$code" ]; then
        country_name=$(printf '%s' "$geo" | jq -r '
            (.country_name // .country // empty)
            | select(type == "string" and length > 0)
        ' 2>/dev/null || true)
        [ -n "$country_name" ] || country_name=$code
        # A failed cache write must not interrupt node installation or querying.
        (umask 077; mkdir -p "$NBASE" && printf '%s\n' "$code" > "$NBASE/country-code" && printf '%s\n' "$country_name" > "$NBASE/country-name") 2>/dev/null || true
    else
        code=$(cat "$NBASE/country-code" 2>/dev/null || true)
        if ! printf '%s' "$code" | grep -Eq '^[A-Z]{2}$'; then
            return 0
        fi
        country_name=$(cat "$NBASE/country-name" 2>/dev/null || true)
        [ -n "$country_name" ] || country_name=$code
    fi
    country_flag=$(jq -nr --arg c "$code" '$c|explode|map(.+127397)|implode' 2>/dev/null || printf '🌐')
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
        # Use the normal terminal so mobile SSH retains scrollback.
        trap 'exit 130' INT
        trap 'exit 143' TERM
    fi
}
terminal_restore() {
    : # Normal terminal: leave output available after exit.
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
        case "$REPLY" in 1) return;; 0) exit 0;; *) retry_input '请输入 0 或 1。';; esac
    done
}
update_node() {
    node_exists || die '尚未安装节点。'
    install_node "$(cat "$NBASE/core")"
}
remove_node() {
    node_exists || die '尚未安装节点。'
    ask '删除节点核心、配置和保存的节点信息？输入 “YES/y” 继续，“NO/n” 取消：'
    confirmed || return 0
    sync_disable
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
    printf '%s  【 ARGO · 隧道与节点管理 】%s\n' "$C_CYAN" "$C_RESET"; status_rule
    printf '  系统  %s%s%s / %s  ·  %sv%s%s\n' "$C_WHITE" "$ID" "$C_RESET" "$MANAGER" "$C_PURPLE" "$VERSION" "$C_RESET"
    if exists; then
        case "$(cat "$BASE/mode")" in quick) label=临时隧道;; *) label=固定隧道;; esac
        if connected; then state=已连接; color=$C_GREEN
        elif control status >/dev/null 2>&1; then state='运行中 · 连接待确认'; color=$C_WARNING
        else state=已停止; color=$C_DIM; fi
        printf '  隧道  %s · %s%s%s\n' "$label" "$color" "$state" "$C_RESET"
    else printf '  隧道  %s未安装%s\n' "$C_DIM" "$C_RESET"; fi
    if node_exists; then
        if node_control status >/dev/null 2>&1; then state=运行中; color=$C_GREEN; else state=已停止; color=$C_DIM; fi
        printf '  核心  %s · %s%s%s\n' "$(cat "$NBASE/core")" "$color" "$state" "$C_RESET"
    else printf '  核心  %s未安装%s\n' "$C_DIM" "$C_RESET"; fi
    status_rule
}
run_action() {
    # Keep operational failures inside a subshell, allowing return to the menu.
    pause_owner=0
    if [ -x "$SYNCBIN" ] && [ ! -f "$APIBASE/pause-pid" ]; then
        mkdir -p "$APIBASE"; (umask 077; printf '%s\n' "$$" > "$APIBASE/pause-pid"); pause_owner=1
    fi
    set +e
    (set -eu; trap cleanup EXIT; "$@")
    action_result=$?
    if [ "$pause_owner" = 1 ]; then rm -f "$APIBASE/pause-pid"; fi
    set -e
    [ "$action_result" != 130 ] && [ "$action_result" != 143 ] || exit "$action_result"
    if [ "$action_result" -ne 0 ]; then warn '操作未完成，请查看上面的错误提示。'; fi
}
# API features are isolated from the original manual deployment functions.
APIBASE=/etc/vps-cf-api
SYNCBIN=/usr/local/lib/vps-cf-sync/run
SYNCSERVICE=vps-cf-sync
valid_uuid() { printf '%s\n' "$1" | grep -Eq '^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$'; }
valid_id() { printf '%s\n' "$1" | grep -Eq '^[a-fA-F0-9]{32}$'; }
api_request() {
    # Keep the credential out of process arguments and error output.
    api_method=$1; api_path=$2; api_output=$3; api_body=${4:-}
    api_headers=$(mktemp "$TMP/headers.XXXXXX")
    chmod 600 "$api_headers"
    printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$api_token" > "$api_headers"
    if [ -n "$api_body" ]; then
        api_http=$(curl -sS --connect-timeout 10 --max-time 30 -X "$api_method" -H "@$api_headers" --data-binary "@$api_body" -o "$api_output" -w '%{http_code}' "https://api.cloudflare.com/client/v4$api_path" 2>/dev/null) || api_http=000
    else
        api_http=$(curl -sS --connect-timeout 10 --max-time 30 -X "$api_method" -H "@$api_headers" -o "$api_output" -w '%{http_code}' "https://api.cloudflare.com/client/v4$api_path" 2>/dev/null) || api_http=000
    fi
    rm -f "$api_headers"
    case "$api_http" in 2??) if jq -e '.success == true' "$api_output" >/dev/null 2>&1; then return 0; fi;; esac
    api_codes=$(jq -r '[.errors[]?.code|tostring]|join(",")' "$api_output" 2>/dev/null || true)
    warn "CF API 请求失败：HTTP $api_http${api_codes:+ / 错误码 $api_codes}。请检查网络、权限与参数。"
    return 1
}
api_collect() {
    # Pagination must not silently omit tunnels or zones.
    list_path=$1; list_out=$2; list_page=1
    printf '[]\n' > "$list_out"
    while :; do
        case "$list_path" in *\?*) list_sep='&';; *) list_sep='?';; esac
        api_request GET "$list_path${list_sep}page=$list_page&per_page=50" "$TMP/list-page.json" || return 1
        jq -e '.result|type == "array"' "$TMP/list-page.json" >/dev/null || return 1
        jq -s '.[0] + .[1].result' "$list_out" "$TMP/list-page.json" > "$TMP/list-next.json"
        mv "$TMP/list-next.json" "$list_out"
        list_pages=$(jq -r '.result_info.total_pages // 1' "$TMP/list-page.json")
        [ "$list_page" -lt "$list_pages" ] || break
        list_page=$((list_page + 1))
        [ "$list_page" -le 100 ] || { warn '列表超过 100 页，请限制 Token 的资源范围。'; return 1; }
    done
}
api_load_auth() {
    [ -s "$APIBASE/auth.json" ] || die '请先选择 1 · API 接入。'
    api_token=$(jq -er '.token' "$APIBASE/auth.json")
    account_id=$(jq -er '.account_id' "$APIBASE/auth.json")
    zone_id=$(jq -er '.zone_id' "$APIBASE/auth.json")
    zone_name=$(jq -er '.zone_name' "$APIBASE/auth.json")
    valid_id "$account_id" && valid_id "$zone_id" || die '保存的 API 参数格式错误，请重新接入。'
}
api_read_id() {
    while :; do
        ask_form "$1"
        id_value=${REPLY:-${2:-}}
        if valid_id "$id_value"; then return; fi
        retry_input '请输入 32 位账户或区域 ID。'
    done
}
api_select_number() {
    while :; do
        ask "$1"
        case "$REPLY" in ''|*[!0-9]*|??????*) retry_input '请输入列表中的序号。'; continue;; esac
        selection=$(printf '%s' "$REPLY" | sed 's/^0*//'); selection=${selection:-0}
        if [ "$selection" -ge 0 ] && [ "$selection" -le "$2" ]; then return; fi
        retry_input '请输入列表中的序号。'
    done
}
api_connect() {
    dependencies
    TMP=$(mktemp -d); chmod 700 "$TMP"
    printf '\n%s  【 CF API 接入 】%s\n' "$C_CYAN" "$C_RESET"; rule
    printf '  %sToken 权限：%s账户 %sCloudflare Tunnel 编辑%s；区域 %sDNS 编辑、Zone 读取%s。\n' "$C_CYAN" "$C_RESET" "$C_PURPLE" "$C_RESET" "$C_PURPLE" "$C_RESET"
    printf '  %sAPI Token 与 Tunnel Token 不同；凭据只保存在本机，不上传仓库。%s\n' "$C_DIM" "$C_RESET"
    old_account=$(jq -r '.account_id // empty' "$APIBASE/auth.json" 2>/dev/null || true)
    while :; do
        ask_form 'API Token（留空沿用已保存值）：'
        api_token=$REPLY
        if [ -z "$api_token" ]; then api_token=$(jq -r '.token // empty' "$APIBASE/auth.json" 2>/dev/null || true); fi
        case "$api_token" in ''|*[!A-Za-z0-9_-]*) retry_input 'Token 为空或格式错误，请重新输入。'; continue;; esac
        api_read_id "Account ID${old_account:+ [$old_account]}：" "$old_account"; account_id=$id_value
        if api_collect "/accounts/$account_id/cfd_tunnel?is_deleted=false" "$TMP/tunnels.json"; then break; fi
        retry_input '账户或隧道读取验证失败，请重新输入。'
    done
    while :; do
        if api_collect "/zones?account.id=$account_id&status=active" "$TMP/zones.json"; then
            jq -r 'to_entries[]|"  \(.key+1). \(.value.name)"' "$TMP/zones.json"
            zone_count=$(jq 'length' "$TMP/zones.json")
            if [ "$zone_count" -gt 0 ]; then
                printf '  0. 手动输入 Zone ID\n'
                api_select_number '选择域名区域：' "$zone_count"
                if [ "$selection" -gt 0 ]; then zone_id=$(jq -r --argjson n "$selection" '.[$n-1].id' "$TMP/zones.json")
                else api_read_id 'Zone ID：'; zone_id=$id_value; fi
            else api_read_id '未找到可用区域，请输入 Zone ID：'; zone_id=$id_value; fi
        else api_read_id '无法列出区域，请输入 Zone ID：'; zone_id=$id_value; fi
        if api_request GET "/zones/$zone_id" "$TMP/zone.json" && jq -e --arg a "$account_id" '.result.account.id == $a and .result.status == "active"' "$TMP/zone.json" >/dev/null; then
            zone_name=$(jq -er '.result.name' "$TMP/zone.json"); break
        fi
        retry_input '区域读取验证失败，或该区域不属于此账户，请重新选择。'
    done
    umask 077; mkdir -p "$APIBASE"; chmod 700 "$APIBASE"
    jq -n --arg t "$api_token" --arg a "$account_id" --arg z "$zone_id" --arg n "$zone_name" '{token:$t,account_id:$a,zone_id:$z,zone_name:$n}' > "$APIBASE/auth.json.new"
    mv "$APIBASE/auth.json.new" "$APIBASE/auth.json"
    unset api_token REPLY
    good "已保存凭据，账户与 $zone_name 的读取验证通过。"
    printf '  写入权限将在实际部署时检查；权限不足会报错并尝试恢复。\n'
}
api_choose_tunnel() {
    api_collect "/accounts/$account_id/cfd_tunnel?is_deleted=false" "$TMP/tunnels.json" || die '无法读取隧道列表。'
    jq '[.[]|select(.config_src == "cloudflare" and .deleted_at == null)]' "$TMP/tunnels.json" > "$TMP/select-tunnels.json"
    printf '\n'; jq -r 'to_entries[]|"  \(.key+1). \(.value.name) · \(.value.id)"' "$TMP/select-tunnels.json"
    printf '  0. 新建隧道\n'
    tunnel_count=$(jq 'length' "$TMP/select-tunnels.json")
    api_select_number '选择已有隧道 / 0 新建：' "$tunnel_count"
    if [ "$selection" -eq 0 ]; then
        tunnel_id=; tunnel_name=
        while :; do
            ask_form '新隧道名称 [argo-node]：'; tunnel_name=${REPLY:-argo-node}
            if [ "${#tunnel_name}" -le 100 ] && printf '%s' "$tunnel_name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]*$'; then break; fi
            retry_input '名称请使用字母、数字、点、下划线或短横线。'
        done
    else tunnel_id=$(jq -r --argjson n "$selection" '.[$n-1].id' "$TMP/select-tunnels.json"); fi
}
api_read_parameters() {
    previous_domain=${domain:-}
    while :; do
        ask_form "固定隧道子域名${previous_domain:+ [$previous_domain]}："
        domain=$(printf '%s' "${REPLY:-$previous_domain}" | tr 'A-Z' 'a-z')
        if valid_domain "$domain"; then
            case "$domain" in *."$zone_name") break;; esac
        fi
        retry_input "请输入 $zone_name 下的完整子域名，例如 node.$zone_name。"
    done
    read_port "${port:-8080}"
    path_default=${ws_path:-/argo}; read_path
    uuid_default=${uuid:-$(cat /proc/sys/kernel/random/uuid)}
    while :; do
        ask_form "UUID [$uuid_default]："; uuid=${REPLY:-$uuid_default}
        valid_uuid "$uuid" && break
        retry_input 'UUID 格式错误，请重新输入。'
    done
    core_default=${core:-sing-box}
    while :; do
        ask_form "节点核心：1 sing-box / 2 Xray [当前 $core_default，留空保留]："
        case "$REPLY" in '') core=$core_default; break;; 1) core=sing-box; break;; 2) core=xray; break;; *) retry_input '请输入 1 或 2。';; esac
    done
    protocol_default=$(cat "$BASE/protocol" 2>/dev/null || printf auto)
    case "$protocol_default" in http2) protocol_choice=2;; quic) protocol_choice=3;; *) protocol_choice=1;; esac
    while :; do
        ask_form "隧道传输：1 自动 / 2 HTTP2 / 3 QUIC [$protocol_choice]："
        case "${REPLY:-$protocol_choice}" in
            1) protocol=auto; break;; 2) protocol=http2; break;; 3) protocol=quic; break;;
            *) retry_input '请输入 1、2 或 3。';;
        esac
    done
}
api_config_body() {
    # Preserve unrelated ingress and all origin settings. Refuse ambiguous path routes.
    jq -e --arg h "$domain" --arg old "$old_hostname" '
      [(.config.ingress // [])[]|select(.hostname == $h or ($old != "" and .hostname == $old))]
      | length <= 1 and all(.[]; (.path // "") == "")
    ' "$TMP/remote-before.json" >/dev/null || die '此域名存在多个路由或路径匹配规则，请先在 CF 后台整理后再部署。'
    jq --arg h "$domain" --arg old "$old_hostname" --arg s "http://127.0.0.1:$port" '
      (.config // {ingress:[{service:"http_status:404"}]}) as $c
      | ($c.ingress // []) as $rules
      | [$rules[]|select(.hostname == $h or ($old != "" and .hostname == $old))][0] as $existing
      | ($rules | map(select(.hostname != $h and ($old == "" or .hostname != $old)))) as $other
      | ($existing // {}) + {hostname:$h,service:$s} | del(.path) as $route
      | {config:($c + {ingress:([$route] + $other)})}
      | if (.config.ingress|any(.[]; (.hostname // "") == "" and (.path // "") == "")) then .
        else .config.ingress += [{service:"http_status:404"}] end
    ' "$TMP/remote-before.json" > "$TMP/remote-after.json"
}
api_service_path() {
    if [ "$MANAGER" = openrc ]; then printf '/etc/init.d/%s' "$1"
    else printf '/etc/systemd/system/%s.service' "$1"; fi
}
api_snapshot() {
    [ ! -d "$BASE" ] || cp -a "$BASE" "$TMP/old-tunnel"
    [ ! -d "$NBASE" ] || cp -a "$NBASE" "$TMP/old-node"
    [ ! -f "$NBIN" ] || cp "$NBIN" "$TMP/old-core"
    [ ! -f "$APIBASE/target.json" ] || cp "$APIBASE/target.json" "$TMP/old-target.json"
    old_tunnel_running=0; old_node_running=0
    control status >/dev/null 2>&1 && old_tunnel_running=1
    node_control status >/dev/null 2>&1 && old_node_running=1
    for snap_service in "$SERVICE" "$NSERVICE"; do
        snap_path=$(api_service_path "$snap_service")
        [ ! -f "$snap_path" ] || cp "$snap_path" "$TMP/$snap_service.service"
        snap_enabled=0
        if [ "$MANAGER" = systemd ]; then
            systemctl is-enabled "$snap_service.service" >/dev/null 2>&1 && snap_enabled=1
        elif rc-update show default 2>/dev/null | grep -q "^[[:space:]]*$snap_service[[:space:]]"; then snap_enabled=1; fi
        printf '%s\n' "$snap_enabled" > "$TMP/$snap_service.enabled"
    done
}
api_rollback() {
    saved_status=$?
    trap - EXIT INT TERM
    set +e
    if [ "${api_committed:-0}" != 1 ]; then
        if [ "${api_local_changed:-0}" = 1 ]; then
            warn '部署未完成，正在恢复本地隧道和节点。'
            control stop >/dev/null 2>&1; node_control stop >/dev/null 2>&1
            rm -rf "$BASE" "$NBASE"; rm -f "$NBIN"
            [ ! -d "$TMP/old-tunnel" ] || cp -a "$TMP/old-tunnel" "$BASE"
            [ ! -d "$TMP/old-node" ] || cp -a "$TMP/old-node" "$NBASE"
            [ ! -f "$TMP/old-core" ] || { cp "$TMP/old-core" "$NBIN"; chmod 755 "$NBIN"; }
            for restore_service in "$SERVICE" "$NSERVICE"; do
                restore_path=$(api_service_path "$restore_service")
                if [ -f "$TMP/$restore_service.service" ]; then cp "$TMP/$restore_service.service" "$restore_path"
                else rm -f "$restore_path"; fi
                restore_enabled=$(cat "$TMP/$restore_service.enabled")
                if [ "$MANAGER" = openrc ]; then
                    if [ "$restore_enabled" = 1 ]; then rc-update add "$restore_service" default >/dev/null 2>&1
                    else rc-update del "$restore_service" default >/dev/null 2>&1; fi
                fi
            done
            if [ "$MANAGER" = systemd ]; then
                systemctl daemon-reload
                for restore_service in "$SERVICE" "$NSERVICE"; do
                    if [ "$(cat "$TMP/$restore_service.enabled")" = 1 ]; then systemctl enable "$restore_service.service" >/dev/null 2>&1
                    else systemctl disable "$restore_service.service" >/dev/null 2>&1; fi
                done
            fi
            [ "$old_tunnel_running" != 1 ] || control start >/dev/null 2>&1
            [ "$old_node_running" != 1 ] || node_control start >/dev/null 2>&1
            rm -f "$APIBASE/target.json"
            [ ! -f "$TMP/old-target.json" ] || cp "$TMP/old-target.json" "$APIBASE/target.json"
        fi
        if [ "${api_remote_changed:-0}" = 1 ] && [ "${api_new_tunnel:-0}" != 1 ]; then
            expected_remote="$TMP/remote-after.json"
            [ ! -s "$TMP/remote-applied.json" ] || expected_remote="$TMP/remote-applied.json"
            if api_request GET "/accounts/$account_id/cfd_tunnel/$tunnel_id/configurations" "$TMP/rollback-current.json" &&
               [ "$(jq -cS '.result.config' "$TMP/rollback-current.json")" = "$(jq -cS '.config' "$expected_remote")" ]; then
                jq '{config:.config}' "$TMP/remote-before.json" > "$TMP/rollback-body.json"
                api_request PUT "/accounts/$account_id/cfd_tunnel/$tunnel_id/configurations" "$TMP/rollback-result.json" "$TMP/rollback-body.json" || warn 'CF 路由恢复失败，请在后台检查。'
            else warn 'CF 配置已被其它操作修改或无法读取，未覆盖它；请检查后台路由。'; fi
        fi
        if [ "${api_name_changed:-0}" = 1 ]; then
            if api_request GET "/accounts/$account_id/cfd_tunnel/$tunnel_id" "$TMP/name-rollback-current.json"; then
                rollback_name=$(jq -r '.result.name' "$TMP/name-rollback-current.json")
                if [ "$rollback_name" = "$new_tunnel_name" ]; then
                    jq -n --arg n "$old_tunnel_name" '{name:$n}' > "$TMP/name-rollback-body.json"
                    api_request PATCH "/accounts/$account_id/cfd_tunnel/$tunnel_id" "$TMP/name-rollback-result.json" "$TMP/name-rollback-body.json" || warn '隧道名称恢复失败，请检查 CF 后台。'
                elif [ "$rollback_name" != "$old_tunnel_name" ]; then warn '隧道名称已被其它操作修改，未覆盖它。'; fi
            else warn '无法确认隧道名称，请检查 CF 后台。'; fi
        fi
        if [ "${api_dns_created:-}" != '' ]; then
            if api_request GET "/zones/$zone_id/dns_records/$api_dns_created" "$TMP/rollback-dns.json" &&
               jq -e --arg h "$domain" --arg t "$tunnel_id.cfargotunnel.com" '.result.name == $h and .result.type == "CNAME" and .result.content == $t' "$TMP/rollback-dns.json" >/dev/null; then
                api_request DELETE "/zones/$zone_id/dns_records/$api_dns_created" "$TMP/delete-dns.json" || warn '新建 DNS 清理失败，请在后台检查。'
            fi
        fi
        if [ "${api_new_tunnel:-0}" = 1 ]; then
            api_request DELETE "/accounts/$account_id/cfd_tunnel/$tunnel_id" "$TMP/delete-tunnel.json" || warn "新建隧道清理失败，请检查 $tunnel_id。"
        fi
    fi
    cleanup
    exit "$saved_status"
}
api_deploy() {
    api_edit=$1
    api_load_auth
    dependencies
    [ -x "$BIN" ] || download
    TMP=$(mktemp -d); chmod 700 "$TMP"
    old_hostname=; domain=; port=8080; ws_path=/argo; uuid=; core=sing-box
    if node_exists; then
        core=$(cat "$NBASE/core"); uuid=$(cat "$NBASE/uuid"); port=$(cat "$NBASE/port"); ws_path=$(cat "$NBASE/path")
    fi
    if [ "$api_edit" = edit ]; then
        [ -s "$APIBASE/target.json" ] || die '尚无 API 部署记录，请先自动部署。'
        jq -e --arg a "$account_id" '.account_id == $a' "$APIBASE/target.json" >/dev/null || die '保存的部署属于其它账户，请切换 API 凭据。'
        tunnel_id=$(jq -er '.tunnel_id' "$APIBASE/target.json")
        domain=$(cat "$BASE/domain"); old_hostname=$domain
        zone_id=$(jq -er '.zone_id' "$APIBASE/target.json")
        zone_name=$(jq -er '.zone_name' "$APIBASE/target.json")
        printf '  修改当前部署：%s\n' "$domain"
    else
        api_choose_tunnel
        if [ -s "$BASE/domain" ]; then domain=$(cat "$BASE/domain"); fi
    fi
    old_tunnel_name=; new_tunnel_name=
    if [ "$api_edit" = edit ]; then
        api_request GET "/accounts/$account_id/cfd_tunnel/$tunnel_id" "$TMP/name-before.json" || die '读取隧道名称失败。'
        old_tunnel_name=$(jq -er '.result.name | select(type == "string" and length > 0)' "$TMP/name-before.json")
        while :; do
            ask_form "隧道名称 [$old_tunnel_name，留空保留]："
            new_tunnel_name=${REPLY:-$old_tunnel_name}
            [ -n "$REPLY" ] || break
            if [ "${#new_tunnel_name}" -le 100 ] && printf '%s' "$new_tunnel_name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]*$'; then break; fi
            retry_input '名称请使用字母、数字、点、下划线或短横线（最多 100 字符）。'
        done
    fi
    api_read_parameters
    # A display-name-only edit never fetches a token or changes routes/local services.
    if [ "$api_edit" = edit ] && node_exists &&
       [ "$domain" = "$(cat "$BASE/domain")" ] && [ "$port" = "$(cat "$NBASE/port")" ] &&
       [ "$uuid" = "$(cat "$NBASE/uuid")" ] && [ "$ws_path" = "$(cat "$NBASE/path")" ] &&
       [ "$core" = "$(cat "$NBASE/core")" ] && [ "$protocol" = "$(cat "$BASE/protocol")" ]; then
        if [ "$new_tunnel_name" != "$old_tunnel_name" ]; then
            ask '应用隧道名称修改？输入 “YES/y” 继续，“NO/n” 取消：'; confirmed || return 0
            jq -n --arg n "$new_tunnel_name" '{name:$n}' > "$TMP/name-body.json"
            api_request PATCH "/accounts/$account_id/cfd_tunnel/$tunnel_id" "$TMP/name-result.json" "$TMP/name-body.json" || die '修改隧道名称失败，请重新查看 CF 中的名称。'
            good "隧道名称已更新：$new_tunnel_name"
        else good '配置未变化。'; fi
        return 0
    fi
    if [ -s "$BASE/metrics-port" ] && [ "$(cat "$BASE/metrics-port")" = "$port" ]; then die '节点端口与隧道监控端口冲突，请换一个端口。'; fi
    if port_busy "$port"; then
        node_exists && node_control status >/dev/null 2>&1 && [ "$(cat "$NBASE/port")" = "$port" ] || die "端口 $port 被其它服务占用。"
    fi
    if node_exists && [ "$(cat "$NBASE/core")" = "$core" ]; then
        cp "$NBIN" "$TMP/core"; chmod 755 "$TMP/core"; core_version=$(cat "$NBASE/version")
    else fetch_core; fi
    # Preserve unrelated local inbounds if the core is unchanged.
    build_config
    if node_exists && [ "$(cat "$NBASE/core")" = "$core" ]; then
        jq -e '[.inbounds[]?|select(.tag == "vless-ws")]|length == 1' "$NBASE/config.json" >/dev/null || die '找不到唯一的 vless-ws 入站，未覆盖手动配置。'
        jq -s '.[0] as $old | .[1].inbounds[0] as $new | $old | .inbounds |= map(if .tag == "vless-ws" then $new else . end)' "$NBASE/config.json" "$TMP/config.json" > "$TMP/merged.json"
        mv "$TMP/merged.json" "$TMP/config.json"
        if [ "$core" = sing-box ]; then "$TMP/core" check -c "$TMP/config.json"; else "$TMP/core" run -test -config "$TMP/config.json"; fi
    elif node_exists && [ "$(jq '.inbounds|length' "$NBASE/config.json")" -gt 1 ]; then
        die '原配置有多个入站，切换核心需先手动迁移其它入站；已取消。'
    fi
    rule; printf '  将部署：%s → http://127.0.0.1:%s\n  核心：%s · WS 路径：%s\n' "$domain" "$port" "$core" "$ws_path"
    ask '应用以上配置？输入 “YES/y” 继续，“NO/n” 取消：'; confirmed || return 0
    api_committed=0; api_local_changed=0; api_remote_changed=0; api_new_tunnel=0; api_dns_created=; api_name_changed=0
    api_snapshot
    trap api_rollback EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM
    if [ -z "$tunnel_id" ]; then
        jq -n --arg n "$tunnel_name" '{name:$n,config_src:"cloudflare"}' > "$TMP/create.json"
        api_request POST "/accounts/$account_id/cfd_tunnel" "$TMP/created.json" "$TMP/create.json" || die '创建隧道失败。'
        tunnel_id=$(jq -er '.result.id' "$TMP/created.json"); api_new_tunnel=1
    fi
    valid_uuid "$tunnel_id" || die 'Tunnel ID 格式错误。'
    api_request GET "/accounts/$account_id/cfd_tunnel/$tunnel_id" "$TMP/tunnel.json" || die '读取隧道失败。'
    jq -e '.result.config_src == "cloudflare"' "$TMP/tunnel.json" >/dev/null || die '只支持 CF 后台管理的隧道。'
    api_request GET "/accounts/$account_id/cfd_tunnel/$tunnel_id/token" "$TMP/token.json" || die '无法获取 Tunnel Token，请检查隧道编辑权限。'
    token=$(jq -er '.result | select(type == "string" and length > 0)' "$TMP/token.json")
    if [ "$api_new_tunnel" = 1 ]; then
        printf '{"config":null}\n' > "$TMP/remote-before.json"
    else
        api_request GET "/accounts/$account_id/cfd_tunnel/$tunnel_id/configurations" "$TMP/remote.json" || die '读取路由失败。'
        jq '.result' "$TMP/remote.json" > "$TMP/remote-before.json"
    fi
    api_config_body
    api_request GET "/zones/$zone_id/dns_records?name=$domain&per_page=100" "$TMP/dns.json" || die '读取 DNS 失败。'
    dns_count=$(jq '.result|length' "$TMP/dns.json")
    if [ "$dns_count" -gt 0 ]; then
        jq -e --arg t "$tunnel_id.cfargotunnel.com" '.result|length == 1 and .[0].type == "CNAME" and .[0].content == $t and .[0].proxied == true' "$TMP/dns.json" >/dev/null || die '域名已有其它 DNS 记录或未开启代理；为避免覆盖，请先处理冲突。'
        dns_id=$(jq -er '.result[0].id' "$TMP/dns.json")
    else
        jq -n --arg h "$domain" --arg t "$tunnel_id.cfargotunnel.com" '{type:"CNAME",name:$h,content:$t,proxied:true,ttl:1}' > "$TMP/dns-body.json"
        api_request POST "/zones/$zone_id/dns_records" "$TMP/dns-new.json" "$TMP/dns-body.json" || die '创建 DNS 失败，请检查 DNS 编辑权限。'
        dns_id=$(jq -er '.result.id' "$TMP/dns-new.json"); api_dns_created=$dns_id
    fi
    # Fetch again before PUT to avoid knowingly overwriting concurrent dashboard edits.
    if [ "$api_new_tunnel" != 1 ]; then
        api_request GET "/accounts/$account_id/cfd_tunnel/$tunnel_id/configurations" "$TMP/remote-check.json" || die '提交前读取路由失败。'
        [ "$(jq -cS '.result.config' "$TMP/remote-check.json")" = "$(jq -cS '.config' "$TMP/remote-before.json")" ] || die 'CF 路由刚被修改，请重新操作。'
    fi
    if [ "$api_edit" = edit ] && [ "$new_tunnel_name" != "$old_tunnel_name" ]; then
        api_request GET "/accounts/$account_id/cfd_tunnel/$tunnel_id" "$TMP/name-check.json" || die '提交前读取隧道名称失败。'
        [ "$(jq -r '.result.name' "$TMP/name-check.json")" = "$old_tunnel_name" ] || die '隧道名称刚被修改，请重新操作。'
        jq -n --arg n "$new_tunnel_name" '{name:$n}' > "$TMP/name-body.json"
        api_name_changed=1
        api_request PATCH "/accounts/$account_id/cfd_tunnel/$tunnel_id" "$TMP/name-result.json" "$TMP/name-body.json" || die '修改隧道名称失败。'
    fi
    api_remote_changed=1
    api_request PUT "/accounts/$account_id/cfd_tunnel/$tunnel_id/configurations" "$TMP/remote-result.json" "$TMP/remote-after.json" || die '更新路由失败。'
    # Use CF's normalized response when deciding whether rollback is still safe.
    if jq -e '.result.config|type == "object"' "$TMP/remote-result.json" >/dev/null; then
        jq '{config:.result.config}' "$TMP/remote-result.json" > "$TMP/remote-applied.json"
    fi
    api_local_changed=1
    stop_if_running; node_stop
    umask 077; mkdir -p "$BASE/home" "$NBASE" /usr/local/lib/vps-node /var/log/vps-tunnel "$APIBASE"
    chmod 700 "$BASE" "$BASE/home" "$NBASE" /usr/local/lib/vps-node "$APIBASE"
    printf '%s\n' fixed > "$BASE/mode"; printf '%s\n' "$domain" > "$BASE/domain"
    printf '%s\n' "$token" > "$BASE/token"; unset token REPLY
    printf '%s\n' "$port" > "$BASE/port"; printf '%s\n' "$ws_path" > "$BASE/ws-path"
    printf '%s\n' "$protocol" > "$BASE/protocol"; rm -f "$BASE/effective-protocol" "$BASE/domain-cache"
    choose_metrics; write_runner; write_service
    cp "$TMP/core" "$NBIN"; chmod 755 "$NBIN"
    cp "$TMP/config.json" "$NBASE/config.json"
    printf '%s\n' "$core" > "$NBASE/core"; printf '%s\n' "$core_version" > "$NBASE/version"
    printf '%s\n' "$uuid" > "$NBASE/uuid"; printf '%s\n' "$ws_path" > "$NBASE/path"; printf '%s\n' "$port" > "$NBASE/port"
    node_service; node_control start; control start
    count=0
    while [ "$count" -lt 10 ]; do
        if node_control status >/dev/null 2>&1 && port_busy "$port"; then break; fi
        sleep 1; count=$((count + 1))
    done
    [ "$count" -lt 10 ] || die '节点未成功监听。'
    wait_connected || die '隧道连接未成功，正在恢复旧配置。'
    jq -n --arg a "$account_id" --arg t "$tunnel_id" --arg z "$zone_id" --arg zn "$zone_name" --arg h "$domain" --arg s "http://127.0.0.1:$port" --arg d "$dns_id" '{account_id:$a,tunnel_id:$t,zone_id:$z,zone_name:$zn,hostname:$h,service:$s,dns_id:$d}' > "$APIBASE/target.json.new"
    mv "$APIBASE/target.json.new" "$APIBASE/target.json"
    sync_stamp
    node_info
    api_committed=1
    sync_install
    good 'API 配置已应用；节点信息后台同步已启用（每 60 秒）。'
    if [ -n "$old_hostname" ] && [ "$old_hostname" != "$domain" ]; then
        printf '  旧域名 %s 的 DNS 保留，确认不再需要后可在 CF 后台删除。\n' "$old_hostname"
    fi
}

api_current_tunnel() {
    local_tunnel_id=
    if [ -s "$APIBASE/target.json" ] && jq -e --arg a "$account_id" '.account_id == $a' "$APIBASE/target.json" >/dev/null; then
        local_tunnel_id=$(jq -r '.tunnel_id // ""' "$APIBASE/target.json")
    elif [ -s "$BASE/token" ]; then
        local_tunnel_id=$(jq -Rr 'try (fromjson) catch .' "$BASE/token" | jq -Rr 'try (@base64d|fromjson|.t // "") catch ""' 2>/dev/null || true)
    fi
}
api_delete_selected() {
    printf '\n  将删除以下 CF 隧道：\n'
    jq -r '.[]|"  · \(.name) · \(.id)"' "$TMP/delete-selected.json"
    printf '  以下关联 DNS 来自当前 API 有权限读取的账户域名区域：\n'
    # Discover all authorized zones, not merely the enrollment zone.
    api_collect "/zones?account.id=$account_id&status=active" "$TMP/delete-zones.json" || die '读取域名区域失败，未执行删除。'
    printf '[]\n' > "$TMP/delete-dns.json"
    jq -r '.[].id' "$TMP/delete-zones.json" > "$TMP/delete-zone-ids"
    while IFS= read -r delete_zone; do
        valid_id "$delete_zone" || die 'Zone ID 格式错误。'
        api_collect "/zones/$delete_zone/dns_records?type=CNAME" "$TMP/zone-dns.json" || die '读取关联 DNS 失败，未执行删除。'
        jq --arg z "$delete_zone" --slurpfile t "$TMP/delete-selected.json" '[.[]|select(.type == "CNAME")|. as $d|$t[0][]|select(($d.content|ascii_downcase|rtrimstr(".")) == ((.id|ascii_downcase)+".cfargotunnel.com"))|$d+{zone_id:$z,tunnel_id:.id}]' "$TMP/zone-dns.json" > "$TMP/matched-dns.json"
        jq -s '.[0]+.[1]' "$TMP/delete-dns.json" "$TMP/matched-dns.json" > "$TMP/delete-dns-next.json"
        mv "$TMP/delete-dns-next.json" "$TMP/delete-dns.json"
    done < "$TMP/delete-zone-ids"
    jq -r '.[]|"  · \(.name) → \(.content)"' "$TMP/delete-dns.json"
    [ "$(jq length "$TMP/delete-dns.json")" != 0 ] || printf '  （未找到关联 DNS）\n'
    warn '将删除选中的 CF 隧道和上述 DNS；权限范围外的 DNS 需自行检查。其它 VPS 若共用隧道也会受影响。'
    ask '确认删除选中的隧道和上述 DNS？输入 “YES/y” 继续，“NO/n” 取消：'; confirmed || return 0
    jq -r '.[].id' "$TMP/delete-selected.json" > "$TMP/delete-tunnel-ids"
    while IFS= read -r delete_id; do
        valid_uuid "$delete_id" || die 'Tunnel ID 格式错误。'
        was_running=0
        if [ "$delete_id" = "$local_tunnel_id" ]; then
            control status >/dev/null 2>&1 && was_running=1
            stop_if_running
        fi
        if ! api_request DELETE "/accounts/$account_id/cfd_tunnel/$delete_id" "$TMP/delete-result.json"; then
            warn "隧道 $delete_id 删除失败，保留它的 DNS。若仍有连接器运行，请先停止后重试。"
            [ "$was_running" != 1 ] || control start || true
            continue
        fi
        if [ "$delete_id" = "$local_tunnel_id" ]; then sync_disable; fi
        good "已删除 CF 隧道：$delete_id"
        jq -r --arg t "$delete_id" '.[]|select(.tunnel_id == $t)|[.zone_id,.id]|@tsv' "$TMP/delete-dns.json" > "$TMP/delete-record-ids"
        while IFS="$(printf '\t')" read -r delete_zone delete_record; do
            # Recheck identity immediately before deleting DNS; never delete a reassigned record.
            if api_request GET "/zones/$delete_zone/dns_records/$delete_record" "$TMP/dns-current.json" &&
               jq -e --arg t "$delete_id.cfargotunnel.com" --arg z "$delete_zone" --arg d "$delete_record" --slurpfile before "$TMP/delete-dns.json" '.result as $r | $r.type == "CNAME" and ($r.content|ascii_downcase|rtrimstr(".")) == $t and any($before[0][]; .zone_id == $z and .id == $d and .name == $r.name)' "$TMP/dns-current.json" >/dev/null; then
                api_request DELETE "/zones/$delete_zone/dns_records/$delete_record" "$TMP/dns-deleted.json" || warn "DNS $delete_record 删除失败，请手动检查。"
            else warn "DNS $delete_record 已变化或无法读取，未删除。"; fi
        done < "$TMP/delete-record-ids"
    done < "$TMP/delete-tunnel-ids"
}
uninstall_menu() {
    if [ -s "$APIBASE/auth.json" ]; then
        dependencies; api_load_auth
        TMP=$(mktemp -d); chmod 700 "$TMP"
        api_current_tunnel
        if api_collect "/accounts/$account_id/cfd_tunnel?is_deleted=false" "$TMP/delete-list.json"; then
            jq '[.[]|select(.deleted_at == null)]' "$TMP/delete-list.json" > "$TMP/delete-active.json"
        else
            warn '无法读取 CF 隧道列表，仍可仅卸载本机隧道。'
            printf '[]\n' > "$TMP/delete-active.json"
        fi
    else
        TMP=$(mktemp -d); chmod 700 "$TMP"; local_tunnel_id=
        printf '[]\n' > "$TMP/delete-active.json"
        warn '尚未接入 API；只能卸载本机隧道。'
    fi
    printf '\n%s  【 卸载隧道 】%s\n' "$C_RED" "$C_RESET"; rule
    # jq is not required for the original local-only uninstall.
    delete_count=0
    if [ -s "$APIBASE/auth.json" ]; then
        delete_count=$(jq length "$TMP/delete-active.json")
        jq -r --arg t "$local_tunnel_id" 'to_entries[]|"  \(.key+1). \(.value.name) · \(.value.id)" + (if .value.id == $t then " · 当前 VPS 使用" else "" end)' "$TMP/delete-active.json"
    fi
    printf '  输入编号删除；多个编号用空格分隔，后回车。例如 2 3。\n'
    menu_item "$C_RED" 'A.' '删除上面列出的所有 CF 隧道'
    menu_item "$C_RED" 'L.' '保留 CF 后台配置，仅卸载本机隧道'
    menu_item "$C_DIM" '0.' '返回首页'
    while :; do
        ask '请输入隧道编号（可多个），或 A / L / 0：'
        case "$REPLY" in
            0) return;; L|l) uninstall; return;;
            A|a) [ "$delete_count" -gt 0 ] || { warn '没有可删除的 CF 隧道。'; continue; }; cp "$TMP/delete-active.json" "$TMP/delete-selected.json"; break;;
            *)
                if ! printf '%s' "$REPLY" | grep -Eq '^[0-9]+( +[0-9]+)*$'; then retry_input '请输入列表中的编号，多个编号用空格分隔后回车，例如 1 2。'; continue; fi
                valid_selection=1
                for chosen in $REPLY; do
                    case "$chosen" in 0*|??????????*) valid_selection=0;; *) [ "$chosen" -ge 1 ] && [ "$chosen" -le "$delete_count" ] || valid_selection=0;; esac
                done
                [ "$valid_selection" = 1 ] || { retry_input '请输入列表中的有效编号。'; continue; }
                jq --arg choices "$REPLY" '($choices|split(" ")|map(select(length>0)|tonumber-1)|unique) as $n|[.[$n[]]]' "$TMP/delete-active.json" > "$TMP/delete-selected.json"
                break;;
        esac
    done
    api_delete_selected
}

api_check_access() {
    api_load_auth
    TMP=$(mktemp -d); chmod 700 "$TMP"
    api_request GET "/accounts/$account_id/cfd_tunnel?is_deleted=false&per_page=1" "$TMP/access-account.json" || die 'API 账户验证失败，请重新接入。'
    api_request GET "/zones/$zone_id" "$TMP/access-zone.json" || die 'API 域名区域验证失败，请重新接入。'
    jq -e --arg a "$account_id" '.result.account.id == $a and .result.status == "active"' "$TMP/access-zone.json" >/dev/null || die '域名区域与账户不匹配。'
}
api_menu() {
    if [ -s "$APIBASE/auth.json" ]; then
        run_action api_check_access
        if [ "$action_result" != 0 ]; then run_action api_connect; [ "$action_result" = 0 ] || return; fi
    else
        printf '  请先接入 CF API。\n'
        run_action api_connect; [ "$action_result" = 0 ] || return
    fi
    while :; do
        printf '\n%s  【 CF API 模式 】%s\n' "$C_CYAN" "$C_RESET"; rule
        printf '  账户：%s已接入%s · 域名区域：%s%s%s\n' "$C_GREEN" "$C_RESET" "$C_CYAN" "$(jq -r '.zone_name' "$APIBASE/auth.json")" "$C_RESET"
        menu_item "$C_GREEN" '1.' '自动部署'
        menu_item "$C_YELLOW" '2.' '修改配置'
        menu_item "$C_YELLOW" '3.' '更换 API 凭据 / 域名区域'
        menu_item "$C_DIM" '0.' '返回上一级'
        ask '请选择 [0–3]：'
        case "$REPLY" in
            1) run_action api_deploy deploy; API_DONE=1; return;;
            2) run_action api_deploy edit; API_DONE=1; return;;
            3) run_action api_connect;;
            0) return;; *) retry_input '请输入 0、1、2 或 3。';;
        esac
    done
}
fixed_menu() {
    while :; do
        printf '\n%s  【 固定隧道安装模式 】%s\n' "$C_CYAN" "$C_RESET"; rule
        menu_item "$C_GREEN" '1.' '手动模式'
        menu_item "$C_GREEN" '2.' 'API 接入模式'
        menu_item "$C_DIM" '0.' '返回首页'
        ask '请选择 [0–2]：'
        case "$REPLY" in 1) run_action setup fixed; return;; 2) API_DONE=0; api_menu; [ "$API_DONE" != 1 ] || return;; 0) return;; *) retry_input '请输入 0、1 或 2。';; esac
    done
}

write_sync_program() {
    cat > "$SYNCBIN.new" <<'SYNC_WORKER'
#!/bin/sh
# Read-only synchronizer. It never writes CF or restarts node/tunnel services.
set -eu
BASE=/etc/vps-tunnel
NBASE=/etc/vps-node
NBIN=/usr/local/lib/vps-node/core
APIBASE=/etc/vps-cf-api
LOG=/var/log/vps-tunnel/cloudflared.log
WORK=
LOCK=/run/vps-cf-sync.lock
cleanup_sync() {
    [ -z "$WORK" ] || rm -rf "$WORK"
    if [ -d "$LOCK" ] && [ "$(cat "$LOCK/pid" 2>/dev/null || true)" = "$$" ]; then rm -rf "$LOCK"; fi
}
trap cleanup_sync EXIT
trap 'exit 0' INT TERM
fail() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; exit 1; }
atomic_text() { printf '%s\n' "$2" > "$1.new"; mv "$1.new" "$1"; }
valid_domain() { [ "${#1}" -le 253 ] && printf '%s\n' "$1" | grep -Eq '^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'; }
api_get() {
    curl -fsS --connect-timeout 5 --max-time 15 -H "@$WORK/headers" "https://api.cloudflare.com/client/v4$1" -o "$2" 2>/dev/null || return 1
    jq -e '.success == true' "$2" >/dev/null 2>&1
}
running() {
    if command -v rc-service >/dev/null 2>&1; then rc-service "$1" status >/dev/null 2>&1
    else systemctl is-active --quiet "$1.service"; fi
}
listen_port() {
    hex=$(printf '%04X' "$1")
    awk -v p="$hex" '$4 == "0A" {split($2,a,":"); if (toupper(a[length(a)]) == p) ok=1} END {exit !ok}' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}
read_node() {
    core=$(cat "$NBASE/core")
    cp "$NBASE/config.json" "$WORK/config.json"
    if [ "$core" = sing-box ]; then
        "$NBIN" check -c "$WORK/config.json" >/dev/null 2>&1 || fail '核心配置校验失败，保留旧链接。'
        jq -e '[.inbounds[]?|select(.tag == "vless-ws" and .type == "vless" and .listen == "127.0.0.1" and .transport.type == "ws" and (.tls.enabled // false) == false)]
          | select(length == 1) | .[0] | select(.users|length == 1)
          | {uuid:.users[0].uuid,path:.transport.path,port:.listen_port}' "$WORK/config.json" > "$WORK/node.json" || fail '无法识别唯一的 VLESS WS 入站，保留旧链接。'
    elif [ "$core" = xray ]; then
        "$NBIN" run -test -config "$WORK/config.json" >/dev/null 2>&1 || fail '核心配置校验失败，保留旧链接。'
        jq -e '[.inbounds[]?|select(.tag == "vless-ws" and .protocol == "vless" and .listen == "127.0.0.1" and .streamSettings.network == "ws" and (.streamSettings.security // "none") == "none")]
          | select(length == 1) | .[0] | select(.settings.clients|length == 1)
          | {uuid:.settings.clients[0].id,path:.streamSettings.wsSettings.path,port:.port}' "$WORK/config.json" > "$WORK/node.json" || fail '无法识别唯一的 VLESS WS 入站，保留旧链接。'
    else fail '未知节点核心，保留旧链接。'; fi
    jq -e '.uuid|type == "string"' "$WORK/node.json" >/dev/null || fail 'UUID 类型错误。'
    uuid=$(jq -r '.uuid' "$WORK/node.json"); ws_path=$(jq -r '.path' "$WORK/node.json"); port=$(jq -r '.port' "$WORK/node.json")
    printf '%s' "$uuid" | grep -Eq '^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$' || fail 'UUID 格式错误。'
    [ "${#ws_path}" -le 128 ] && printf '%s' "$ws_path" | grep -Eq '^/[A-Za-z0-9/._~-]*$' || fail 'WS 路径格式错误。'
    case "$port" in ''|*[!0-9]*|??????*) fail '端口格式错误。';; esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || fail '端口范围错误。'
    running vps-node && listen_port "$port" || fail '节点未运行或未监听新端口，保留旧链接。'
    # Restart through the manager after editing. A new hash cannot prove a live reload.
    config_sha=$(sha256sum "$WORK/config.json" | awk '{print $1}')
    if [ "$config_sha" != "$(cat "$NBASE/active-config-sha" 2>/dev/null || true)" ]; then
        fail '磁盘配置尚未确认已由核心加载；请选择 10 重启节点，再自动同步。'
    fi
}
read_domain() {
    mode=$(cat "$BASE/mode")
    running vps-tunnel || fail '隧道已停止，保留旧链接。'
    case "$mode" in
      quick)
        domain=$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG" 2>/dev/null | tail -n 1 || true)
        domain=${domain#https://}
        [ "$(cat "$BASE/port")" = "$port" ] || fail '临时隧道端口与核心不一致，保留旧链接。'
        ;;
      fixed)
        if [ -s "$APIBASE/target.json" ]; then
            cp "$APIBASE/target.json" "$WORK/target.json"
            a=$(jq -er '.account_id' "$WORK/target.json"); t=$(jq -er '.tunnel_id' "$WORK/target.json")
            z=$(jq -er '.zone_id' "$WORK/target.json"); old=$(jq -er '.hostname' "$WORK/target.json")
            svc=$(jq -er '.service' "$WORK/target.json")
            jq -e --arg a "$a" '.account_id == $a' "$APIBASE/auth.json" >/dev/null || fail 'API 凭据账户不匹配。'
            token=$(jq -er '.token' "$APIBASE/auth.json")
            printf 'Authorization: Bearer %s\n' "$token" > "$WORK/headers"; unset token
            api_get "/accounts/$a/cfd_tunnel/$t/configurations" "$WORK/remote.json" || fail 'CF API 读取失败，保留旧链接。'
            jq --arg h "$old" --arg s "$svc" '
              [.result.config.ingress[]?|select(.hostname != null and (.path // "") == "")] as $r
              | [$r[]|select(.hostname == $h)] as $same
              | if ($same|length) == 1 then $same
                elif ($same|length) == 0 then [$r[]|select(.service == $s)] else [] end
              | select(length == 1) | .[0]
            ' "$WORK/remote.json" > "$WORK/route.json"
            [ -s "$WORK/route.json" ] || fail '路由被删除或有多个候选域名，无法安全识别；请重新选择 API 部署。'
            domain=$(jq -er '.hostname' "$WORK/route.json")
            remote_service=$(jq -er '.service' "$WORK/route.json")
            case "$remote_service" in "http://127.0.0.1:$port"|"http://localhost:$port") :;; *) fail 'CF 服务地址与本地 WS 监听不一致，请通过修改配置处理。';; esac
            zn=$(jq -er '.zone_name' "$WORK/target.json")
            case "$domain" in *."$zn") :;; *) fail '新域名不属于选定区域，保留旧链接。';; esac
            api_get "/zones/$z/dns_records?name=$domain&per_page=100" "$WORK/dns.json" || fail '域名 DNS 读取失败。'
            jq -e --arg t "$t.cfargotunnel.com" '.result|length == 1 and .[0].type == "CNAME" and .[0].content == $t and .[0].proxied == true' "$WORK/dns.json" >/dev/null || fail '域名 DNS 未正确指向此隧道，保留旧链接。'
            dns=$(jq -er '.result[0].id' "$WORK/dns.json")
            jq --arg h "$domain" --arg s "$remote_service" --arg d "$dns" '.hostname=$h | .service=$s | .dns_id=$d' "$WORK/target.json" > "$WORK/new-target.json"
        else
            domain=$(cat "$BASE/domain")
            [ "$(cat "$BASE/port")" = "$port" ] || fail '手动固定隧道端口记录与核心不一致，请同步 CF 路由和本地记录。'
        fi
        ;;
      *) fail '未知隧道模式。';;
    esac
    valid_domain "$domain" || fail '未找到有效域名，保留旧链接。'
    [ -s "$BASE/metrics-port" ] || fail '缺少隧道就绪检查端口。'
    curl --noproxy '*' -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:$(cat "$BASE/metrics-port")/ready" >/dev/null 2>&1 || fail '隧道尚未连接，保留旧链接。'
}
sync_once() {
    sync_foreground=${1:-}
    umask 077
    if [ -f "$APIBASE/pause-pid" ] && [ "${1:-}" != foreground ]; then
        pause_pid=$(cat "$APIBASE/pause-pid")
        if kill -0 "$pause_pid" 2>/dev/null; then exit 0; fi
        rm -f "$APIBASE/pause-pid"
    fi
    mkdir "$LOCK" 2>/dev/null || {
        lock_pid=$(cat "$LOCK/pid" 2>/dev/null || true)
        case "$lock_pid" in
          ''|*[!0-9]*)
            lock_time=$(stat -c %Y "$LOCK" 2>/dev/null || date +%s)
            [ "$(( $(date +%s) - lock_time ))" -ge 30 ] || exit 0
            ;;
          *) if kill -0 "$lock_pid" 2>/dev/null; then exit 0; fi;;
        esac
        rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 0
    }
    printf '%s\n' "$$" > "$LOCK/pid"
    [ -s "$NBASE/config.json" ] && [ -x "$NBIN" ] && [ -s "$BASE/mode" ] || exit 0
    WORK=$(mktemp -d)
    read_node; read_domain
    flag=🌐; name=未知
    code=$(cat "$NBASE/country-code" 2>/dev/null || true)
    if printf '%s' "$code" | grep -Eq '^[A-Z]{2}$'; then
        flag=$(jq -nr --arg c "$code" '$c|explode|map(.+127397)|implode')
        name=$(cat "$NBASE/country-name" 2>/dev/null || printf '%s' "$code")
    fi
    case "$core" in sing-box) label="Argo-singbox-$flag";; *) label="Argo-Xray-$flag";; esac
    encoded_label=$(jq -nr --arg s "$label" '$s|@uri'); encoded_path=$(jq -nr --arg s "$ws_path" '$s|@uri')
    link="vless://$uuid@$domain:443?encryption=none&security=tls&sni=$domain&type=ws&host=$domain&path=$encoded_path#$encoded_label"
    version=$(cat "$NBASE/version")
    printf '%s\n' "$link" > "$WORK/node-link.txt"
    {
      printf '节点名称：%s\n出口地区：%s\n\n' "$label" "$name"
      printf '核心：%s %s\n' "$core" "$version"
      printf '域名：%s\n客户端端口：443\n本地监听：127.0.0.1:%s\n' "$domain" "$port"
      printf '协议：VLESS\nUUID：%s\n传输：WebSocket\nWS 路径：%s\n' "$uuid" "$ws_path"
      printf '客户端 TLS：开启\nSNI / WS Host：%s\n本地 TLS：关闭\n\n%s\n' "$domain" "$link"
    } > "$WORK/node-info.txt"
    # Ensure the config did not change while network requests were in progress.
    [ "$config_sha" = "$(sha256sum "$NBASE/config.json" | awk '{print $1}')" ] || fail '检查期间核心配置变化，下次重试。'
    if [ -f "$APIBASE/pause-pid" ] && [ "$sync_foreground" != foreground ]; then
        pause_pid=$(cat "$APIBASE/pause-pid")
        if kill -0 "$pause_pid" 2>/dev/null; then exit 0; fi
    fi
    if [ -f "$WORK/target.json" ] && ! cmp -s "$WORK/target.json" "$APIBASE/target.json"; then
        fail '检查期间部署目标变化，下次重试。'
    fi
    changed=0
    for file in node-info.txt node-link.txt; do
        if ! cmp -s "$WORK/$file" "$NBASE/$file"; then
            cp "$WORK/$file" "$NBASE/$file.new"; mv "$NBASE/$file.new" "$NBASE/$file"; changed=1
        fi
    done
    for field in uuid path port; do
        case "$field" in uuid) value=$uuid;; path) value=$ws_path;; port) value=$port;; esac
        if [ "$(cat "$NBASE/$field" 2>/dev/null || true)" != "$value" ]; then atomic_text "$NBASE/$field" "$value"; fi
    done
    if [ "$(cat "$BASE/port")" != "$port" ]; then atomic_text "$BASE/port" "$port"; fi
    if [ "$(cat "$BASE/ws-path" 2>/dev/null || true)" != "$ws_path" ]; then atomic_text "$BASE/ws-path" "$ws_path"; fi
    if [ "$mode" = fixed ] && [ -f "$WORK/new-target.json" ]; then
        if ! cmp -s "$WORK/new-target.json" "$APIBASE/target.json"; then cp "$WORK/new-target.json" "$APIBASE/target.json.new"; mv "$APIBASE/target.json.new" "$APIBASE/target.json"; fi
        if [ "$(cat "$BASE/domain")" != "$domain" ]; then atomic_text "$BASE/domain" "$domain"; fi
    fi
    if [ "$changed" = 1 ]; then
        printf '%s 已更新节点信息：%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$domain"
        atomic_text "$APIBASE/last-sync" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    fi
}
case "${1:-}" in
  --once) sync_once "${2:-}";;
  *)
    child=
    trap '[ -z "$child" ] || kill "$child" 2>/dev/null || true; exit 0' INT TERM
    while :; do
        "$0" --once & child=$!
        wait "$child" || true; child=
        sleep 60 & child=$!
        wait "$child" || true; child=
    done
    ;;
esac
SYNC_WORKER
    chmod 700 "$SYNCBIN.new"
    mv "$SYNCBIN.new" "$SYNCBIN"
}
sync_control() {
    if [ "$MANAGER" = openrc ]; then rc-service "$SYNCSERVICE" "$1"
    else systemctl "$1" "$SYNCSERVICE.service"; fi
}
sync_disable() {
    if [ -x "$SYNCBIN" ]; then
        sync_control stop >/dev/null 2>&1 || true
        if [ "$MANAGER" = openrc ]; then rc-update del "$SYNCSERVICE" default >/dev/null 2>&1 || true
        else systemctl disable "$SYNCSERVICE.service" >/dev/null 2>&1 || true; fi
    fi
    rm -f "$APIBASE/target.json"
}
sync_remove() {
    sync_disable
    if [ "$MANAGER" = openrc ]; then rm -f /etc/init.d/vps-cf-sync
    else rm -f /etc/systemd/system/vps-cf-sync.service; systemctl daemon-reload; fi
    rm -rf /usr/local/lib/vps-cf-sync "$APIBASE"
    rm -f /var/log/vps-cf-sync.log
}
sync_install() {
    umask 077
    mkdir -p /usr/local/lib/vps-cf-sync "$APIBASE"
    chmod 700 /usr/local/lib/vps-cf-sync "$APIBASE"
    write_sync_program
    if [ "$MANAGER" = openrc ]; then
        cat > /etc/init.d/vps-cf-sync <<'RC'
#!/sbin/openrc-run
name="Argo node information synchronizer"
supervisor="supervise-daemon"
command="/usr/local/lib/vps-cf-sync/run"
respawn_delay=5
respawn_max=0
respawn_period=60
output_log="/var/log/vps-cf-sync.log"
error_log="/var/log/vps-cf-sync.log"
depend() { need net; after vps-tunnel vps-node; }
RC
        chmod 755 /etc/init.d/vps-cf-sync
        rc-update add "$SYNCSERVICE" default
    else
        cat > /etc/systemd/system/vps-cf-sync.service <<'UNIT'
[Unit]
Description=Argo node information synchronizer
Wants=network-online.target
After=network-online.target vps-tunnel.service vps-node.service
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStart=/usr/local/lib/vps-cf-sync/run
Restart=always
RestartSec=5
UMask=0077
StandardOutput=append:/var/log/vps-cf-sync.log
StandardError=append:/var/log/vps-cf-sync.log
[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable "$SYNCSERVICE.service"
    fi
    sync_control restart || die '节点已部署，但后台同步服务启动失败，请查看 vps-cf-sync 日志。'
}
sync_stamp() {
    # Called only after the node manager successfully starts/restarts the core.
    if [ -s "$NBASE/config.json" ]; then
        (umask 077; sha256sum "$NBASE/config.json" | awk '{print $1}' > "$NBASE/active-config-sha.new"; mv "$NBASE/active-config-sha.new" "$NBASE/active-config-sha")
    fi
}

bbr_read() { sysctl -n "$1" 2>/dev/null; }
bbr_supported() {
    bbr_available=$(bbr_read net.ipv4.tcp_available_congestion_control || true)
    case " $bbr_available " in *' bbr '*) return 0;; *) return 1;; esac
}
bbr_status() {
    printf '\n%s  【 BBR 管理 】%s\n' "$C_CYAN" "$C_RESET"; rule
    printf '  内核：%s\n' "$(uname -r)"
    bbr_current=$(bbr_read net.ipv4.tcp_congestion_control || printf 无法读取)
    printf '  当前拥塞控制：%s%s%s\n' "$C_PURPLE" "$bbr_current" "$C_RESET"
    if bbr_supported; then good '内核已提供 BBR。'
    else warn '当前未发现 BBR；开启时会尝试加载内核模块。'; fi
    printf '  默认队列规则：%s%s%s\n' "$C_PURPLE" "$(bbr_read net.core.default_qdisc || printf 无法读取)" "$C_RESET"
    if [ -s /etc/sysctl.d/99-zz-argo-bbr.conf ]; then
        printf '  %s已保存开机参数。%s\n' "$C_GREEN" "$C_RESET"
    fi
}
bbr_restore() {
    bbr_exit=$?
    trap - EXIT INT TERM
    set +e
    if [ "${bbr_committed:-0}" != 1 ]; then
        if [ "${bbr_runtime_changed:-0}" = 1 ]; then
            sysctl -w "net.ipv4.tcp_congestion_control=$bbr_old_cc" >/dev/null 2>&1 || warn '拥塞控制恢复失败，请检查系统参数。'
            [ -z "$bbr_old_qdisc" ] || sysctl -w "net.core.default_qdisc=$bbr_old_qdisc" >/dev/null 2>&1 || warn '默认队列恢复失败，请检查系统参数。'
        fi
        if [ "${bbr_files_changed:-0}" = 1 ]; then
            for bbr_file in "$bbr_sysfile" "$bbr_modfile"; do
                bbr_basename=$(basename "$bbr_file")
                if [ -f "$TMP/$bbr_basename.old" ]; then cp -p "$TMP/$bbr_basename.old" "$bbr_file"
                else rm -f "$bbr_file"; fi
            done
        fi
        if [ "$MANAGER" = openrc ]; then
            [ "${bbr_added_modules:-0}" != 1 ] || rc-update del modules boot >/dev/null 2>&1
            [ "${bbr_added_sysctl:-0}" != 1 ] || rc-update del sysctl boot >/dev/null 2>&1
        fi
    fi
    cleanup
    exit "$bbr_exit"
}
bbr_enable() {
    command -v sysctl >/dev/null 2>&1 || die '系统缺少 sysctl，无法设置 BBR。'
    bbr_old_cc=$(bbr_read net.ipv4.tcp_congestion_control) || die '无法读取 TCP 拥塞控制参数。'
    bbr_old_qdisc=$(bbr_read net.core.default_qdisc || true)
    ask '开启 BBR 并保存开机参数？输入 “YES/y” 继续，“NO/n” 取消：'
    confirmed || return 0
    if ! bbr_supported; then
        if command -v modprobe >/dev/null 2>&1; then modprobe tcp_bbr 2>/dev/null || true; fi
        bbr_supported || die '当前内核不支持 BBR，或容器不允许加载模块；未修改参数。请使用宿主机提供的内核支持。'
    fi
    [ -z "$bbr_old_qdisc" ] || { command -v modprobe >/dev/null 2>&1 && modprobe sch_fq 2>/dev/null || true; }
    bbr_sysfile=/etc/sysctl.d/99-zz-argo-bbr.conf
    if [ "$MANAGER" = openrc ]; then
        [ -f /etc/init.d/sysctl ] && [ -f /etc/init.d/modules ] || die '缺少 OpenRC sysctl/modules 服务，无法保证开机应用。'
        bbr_modfile=/etc/modules
    else bbr_modfile=/etc/modules-load.d/argo-bbr.conf; fi
    # Only these two owned/preserved files and the two sysctl keys are changed.
    TMP=$(mktemp -d); chmod 700 "$TMP"
    bbr_committed=0; bbr_runtime_changed=0; bbr_files_changed=0
    bbr_added_modules=0; bbr_added_sysctl=0
    for bbr_file in "$bbr_sysfile" "$bbr_modfile"; do
        [ ! -L "$bbr_file" ] || die 'BBR 参数文件是符号链接，未覆盖它。'
        [ ! -f "$bbr_file" ] || cp -p "$bbr_file" "$TMP/$(basename "$bbr_file").old"
    done
    trap bbr_restore EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM
    bbr_runtime_changed=1
    # Test effective writes first; a restricted container must not receive a success message.
    if [ -n "$bbr_old_qdisc" ]; then
        sysctl -w net.core.default_qdisc=fq >/dev/null || die '默认队列写入被拒绝，正在恢复原设置。'
        [ "$(bbr_read net.core.default_qdisc)" = fq ] || die '默认队列验证失败，正在恢复原设置。'
    else warn '当前环境没有默认队列参数，将仅开启 TCP BBR。'; fi
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null || die 'BBR 写入被拒绝；容器可能没有权限，正在恢复原设置。'
    [ "$(bbr_read net.ipv4.tcp_congestion_control)" = bbr ] || die 'BBR 验证失败，正在恢复原设置。'
    {
        printf '# Managed by ARGO BBR menu\n'
        [ -z "$bbr_old_qdisc" ] || printf 'net.core.default_qdisc = fq\n'
        printf 'net.ipv4.tcp_congestion_control = bbr\n'
    } > "$TMP/sysctl.new"
    if [ "$MANAGER" = openrc ]; then
        if [ -f "$bbr_modfile" ]; then cp -p "$bbr_modfile" "$TMP/modules.new"
        else : > "$TMP/modules.new"; fi
        for bbr_module in tcp_bbr sch_fq; do
            [ "$bbr_module" != sch_fq ] || [ -n "$bbr_old_qdisc" ] || continue
            grep -Eq "^[[:space:]]*$bbr_module([[:space:]]|$)" "$TMP/modules.new" || printf '\n%s\n' "$bbr_module" >> "$TMP/modules.new"
        done
    else
        printf '# Managed by ARGO BBR menu\ntcp_bbr\n' > "$TMP/modules.new"
        [ -z "$bbr_old_qdisc" ] || printf 'sch_fq\n' >> "$TMP/modules.new"
    fi
    mkdir -p /etc/sysctl.d "$(dirname "$bbr_modfile")"
    bbr_files_changed=1
    # Stage in the destination directory so replacement is atomic on that filesystem.
    cp "$TMP/sysctl.new" "$bbr_sysfile.new"; chmod 644 "$bbr_sysfile.new"; mv "$bbr_sysfile.new" "$bbr_sysfile"
    cp "$TMP/modules.new" "$bbr_modfile.new"; chmod 644 "$bbr_modfile.new"; mv "$bbr_modfile.new" "$bbr_modfile"
    if [ "$MANAGER" = openrc ]; then
        for bbr_service in modules sysctl; do
            if ! rc-update show boot 2>/dev/null | grep -q "^[[:space:]]*$bbr_service[[:space:]]"; then
                case "$bbr_service" in modules) bbr_added_modules=1;; sysctl) bbr_added_sysctl=1;; esac
                rc-update add "$bbr_service" boot || die '开机服务设置失败，正在恢复原设置。'
            fi
        done
    fi
    bbr_committed=1
    good 'BBR 已开启，开机参数已保存。'
    printf '  %sBBR 作用于新建 TCP 连接；QUIC 使用 UDP，不受此设置控制。%s\n' "$C_DIM" "$C_RESET"
    if [ -n "$bbr_old_qdisc" ]; then
        printf '  %s默认队列已设置 fq；现有网卡队列未强制替换，不一定立即变化。%s\n' "$C_DIM" "$C_RESET"
    fi
}
bbr_current_status() {
    printf '\n%s  【 当前 BBR 状态 】%s\n' "$C_CYAN" "$C_RESET"; rule
    bbr_current=$(bbr_read net.ipv4.tcp_congestion_control || true)
    case "$bbr_current" in
        bbr) good '当前 TCP 拥塞控制：BBR（已开启）';;
        '') warn '当前 TCP 拥塞控制：无法读取（无法确认是否开启 BBR）';;
        *) warn "当前 TCP 拥塞控制：$bbr_current（未使用 BBR）";;
    esac
    bbr_queue=$(bbr_read net.core.default_qdisc || true)
    printf '  默认队列规则：%s%s%s\n' "$C_PURPLE" "${bbr_queue:-此环境无法读取}" "$C_RESET"
    if [ -s /etc/sysctl.d/99-zz-argo-bbr.conf ] &&
       grep -Eq '^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr([[:space:]]|$)' /etc/sysctl.d/99-zz-argo-bbr.conf; then
        printf '  开机参数：%s已保存%s\n' "$C_GREEN" "$C_RESET"
    else
        printf '  开机参数：%s本脚本未保存%s\n' "$C_DIM" "$C_RESET"
    fi
}

bbr_menu() {
    while :; do
        bbr_status
        menu_item "$C_INSTALL" '1.' '开启 BBR（保存开机参数）'
        menu_item "$C_BLUE" '2.' '查看状态'
        menu_item "$C_DIM" '0.' '返回首页'
        ask '请选择 [0–2]：'
        case "$REPLY" in
            1) run_action bbr_enable;;
            2) bbr_current_status; ask '按回车返回 BBR 菜单：';;
            0) return;;
            *) retry_input '请输入 0、1 或 2。';;
        esac
    done
}

singbox_standalone_install() {
    case "$1" in
        debian) standalone_url=https://raw.githubusercontent.com/Alsyok/kyo/main/singbox.sh;;
        alpine) standalone_url=https://raw.githubusercontent.com/Alsyok/kyo/main/Encrypt.sh;;
        *) die '未知安装选项。';;
    esac
    if ! command -v bash >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        if [ "$MANAGER" = openrc ]; then
            apk add --no-cache bash curl ca-certificates
        else
            apt-get update
            apt-get install -y bash curl ca-certificates
        fi
    fi
    TMP=$(mktemp -d); chmod 700 "$TMP"
    printf '\n  %s正在下载 sing-box 安装脚本…%s\n' "$C_CYAN" "$C_RESET"
    curl -fLsS --retry 2 --connect-timeout 15 --max-time 120 "$standalone_url" -o "$TMP/install.sh" || die '安装脚本下载失败，请稍后重试。'
    [ -s "$TMP/install.sh" ] || die '下载的安装脚本为空。'
    bash -n "$TMP/install.sh" || die '安装脚本语法检查失败，未执行。'
    bash "$TMP/install.sh"
}
standalone_tools() {
    if ! command -v python3 >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v socat >/dev/null 2>&1; then
        if [ "$MANAGER" = openrc ]; then apk add --no-cache python3 openssl curl ca-certificates socat;
        else apt-get update; apt-get install -y python3 openssl curl ca-certificates socat; fi
    fi
    mkdir -p /usr/local/lib/argo-standalone
    chmod 700 /usr/local/lib/argo-standalone
    standalone_helper_tmp=$(mktemp /usr/local/lib/argo-standalone/.manager.XXXXXX)
    cat > "$standalone_helper_tmp" <<'ARGO_STANDALONE_PY'
#!/usr/bin/env python3
"""Independent sing-box and certificate management; never manages vps-node."""
import threading,signal,textwrap,contextlib,functools,base64,copy,datetime,fcntl,getpass,hashlib,importlib.util,ipaddress,json,os,pathlib,re,secrets,shutil,socket,ssl,subprocess,sys,tarfile,tempfile,time,urllib.parse,urllib.request,uuid
ROOT=pathlib.Path('/etc/argo-certificates')
LIB=pathlib.Path('/usr/local/lib/argo-standalone')
CONFIG=pathlib.Path('/etc/sing-box/config.json')
META=pathlib.Path('/var/lib/singbox-node-sync/deployment.json')
RUN=pathlib.Path('/run/singbox-node-sync')
SELF=LIB/'manager.py'
SYNC=LIB/'node-sync.py'
LINKFILES=(pathlib.Path('/root/singbox_nodes.txt'),pathlib.Path('/etc/sing-box/v2rayn_links.txt'))
RC_CORE=pathlib.Path('/etc/init.d/sing-box')
RC_SYNC=pathlib.Path('/etc/init.d/argo-sb-sync')
COLORS={'title':'#81CED6','number':'#DCE3EB','install':'#90EE90','query':'#88B3DF','edit':'#DFC58A','default':'#B5A1DF','prompt':'#9ACD32','ok':'#97CBA8','warn':'#E5C07B','error':'#FF5555','retry':'#C084FC','dim':'#A4AFBE','link':'#FFFACD'}
def color(key,text):
    if not sys.stdout.isatty() or os.environ.get('TERM','dumb')=='dumb' or os.environ.get('NO_COLOR'):return str(text)
    rgb=COLORS[key].lstrip('#');r,g,b=(int(rgb[i:i+2],16) for i in (0,2,4))
    return f'\033[38;2;{r};{g};{b}m{text}\033[0m'
def say(text,key='title'):print('  '+color(key,text),flush=True)
def title(text):print();say('【 '+text+' 】');say('──────────────────────────────────────────','dim')
def item(n,text,key='query'):print('  '+color('number',str(n)+'.')+'  '+color(key,text))
def prompt(text,default='',secret=False):
    tail=' '+color('default','['+str(default)+']') if default!='' else ''
    label='  '+color('prompt',text)+tail+'：'
    try:
        value=(getpass.getpass(label) if secret and sys.stdin.isatty() else input(label)).strip().strip('\r')
    except EOFError:raise Cancel()
    return value if value else str(default)
def choose(text,options,default=''):
    while True:
        value=prompt(text,default)
        if value in options:return value
        say('↻ 请输入列表中的选项。','retry')
def confirm(text):
    while True:
        value=prompt(text+' '+color('default','输入 “YES/y” 继续，“NO/n” 取消')).lower()
        if value in ('yes','y'):return True
        if value in ('no','n'):return False
        say('↻ 请输入 “YES/y” 或 “NO/n”。','retry')
class Cancel(Exception):pass
class Error(Exception):pass
def atomic(path,data,mode=0o600):
    path=pathlib.Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(dir=path.parent)
    try:
        os.fchmod(fd,mode)
        with os.fdopen(fd,'wb') as f:f.write(data.encode() if isinstance(data,str) else data);f.flush();os.fsync(f.fileno())
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)
_lock_depth=0
@contextlib.contextmanager
def management_lock():
    global _lock_depth
    if _lock_depth:
        _lock_depth+=1
        try:yield
        finally:_lock_depth-=1
        return
    with open(ROOT/'manager.lock','a') as f:
        try:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:raise Error('已有申请或配置修改正在进行，请先完成或取消原操作。')
        _lock_depth=1
        try:yield
        finally:
            _lock_depth=0;fcntl.flock(f,fcntl.LOCK_UN)
def locked(func):
    @functools.wraps(func)
    def wrapper(*args,**kwargs):
        with management_lock():return func(*args,**kwargs)
    return wrapper
def read(path):return json.loads(pathlib.Path(path).read_text())
def write(path,obj):atomic(path,json.dumps(obj,ensure_ascii=False,indent=2)+'\n')
def managed_run(args,input=None,timeout=None,stream_log=None,**kwargs):
    # Each command owns a process group so cancellation also stops its descendants.
    if input is not None:kwargs['stdin']=subprocess.PIPE
    if stream_log is not None:kwargs.update(stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    child=subprocess.Popen([str(a) for a in args],start_new_session=True,**kwargs)
    reader=None
    if stream_log is not None:
        def forward():
            env=kwargs.get('env') or {}
            private=[str(v) for k,v in env.items() if v and any(word in k.upper() for word in ('TOKEN','SECRET','PASSWORD','CF_KEY','API_KEY'))]
            for raw in iter(child.stdout.readline,b''):
                text=raw.decode(errors='replace')
                for value in private:text=text.replace(value,'[已隐藏]')
                stream_log.write(text.encode());stream_log.flush()
                try:sys.stdout.write(text);sys.stdout.flush()
                except (BrokenPipeError,OSError):pass
        reader=threading.Thread(target=forward,daemon=True);reader.start()
    try:
        if reader is not None:
            if input is not None:
                child.stdin.write(input);child.stdin.close()
            child.wait(timeout=timeout);reader.join(timeout=3);out=err=None
        else:out,err=child.communicate(input=input,timeout=timeout)
        return subprocess.CompletedProcess(args,child.returncode,out,err)
    except BaseException:
        try:os.killpg(child.pid,signal.SIGTERM)
        except ProcessLookupError:pass
        try:child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            try:os.killpg(child.pid,signal.SIGKILL)
            except ProcessLookupError:pass
            child.wait()
        # A child may exit before its descendants; remove any remaining group members.
        try:os.killpg(child.pid,signal.SIGKILL)
        except ProcessLookupError:pass
        if reader is not None:reader.join(timeout=3)
        raise

def call(args,timeout=30,input=None,env=None,log=None,allowed=(0,)):
    if log:
        pathlib.Path(log).parent.mkdir(parents=True,exist_ok=True)
        with open(log,'ab') as f:
            os.chmod(log,0o600)
            if sys.stdin.isatty():result=managed_run(args,input=input,timeout=timeout,env=env,stream_log=f)
            else:result=managed_run(args,input=input,stdout=f,stderr=f,timeout=timeout,env=env)
    else:result=managed_run([str(a) for a in args],input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout,env=env)
    if result.returncode not in allowed:raise Error('命令执行失败：'+str(args[0]).split('/')[-1]+('；日志：'+str(log) if log else '，请检查参数、服务或文件'))
    return result.stdout if not log else b''
def alpine():return pathlib.Path('/etc/alpine-release').exists()
def service(action):
    return call(['rc-service','sing-box',action] if alpine() else ['systemctl',action,'sing-box.service'],timeout=60)
def active():
    try:service('status' if alpine() else 'is-active');return True
    except Exception:return False
def binary():
    result=shutil.which('sing-box')
    if not result:raise Error('尚未安装独立 sing-box，请先选“安装 sing-box”。')
    return result
def config():
    if not CONFIG.exists():raise Error('没有 /etc/sing-box/config.json；此菜单仅管理独立 sing-box。')
    return read(CONFIG)
def domain(value,wildcard=False):
    value=value.strip().lower().rstrip('.')
    check=value[2:] if wildcard and value.startswith('*.') else value
    if len(check)>253 or not re.fullmatch(r'(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}',check):raise Error('请输入完整域名，不含 https://、端口和路径。')
    return value
def domain_input(text,default='',wildcard=False):
    while True:
        value=prompt(text,default)
        try:return domain(value,wildcard)
        except Error as e:say('↻ '+str(e),'retry')
def port_input(old,label="监听端口"):
    while True:
        v=prompt(label,old)
        if v.isdigit() and 1<=int(v)<=65535:return int(v)
        say('↻ 端口应为 1–65535。','retry')
def uuid_input(old):
    while True:
        value=prompt('UUID（输入 G 自动生成，留空保留）',old)
        if value.lower()=='g':return str(uuid.uuid4())
        try:return str(uuid.UUID(value))
        except ValueError:say('↻ UUID 格式不正确。','retry')
def registry():
    path=ROOT/'registry.json'
    return read(path) if path.exists() else {}
def save_registry(db):write(ROOT/'registry.json',db)
def decode_cert(path):
    try:return ssl._ssl._test_decode_cert(str(path))
    except Exception:raise Error('证书 PEM 无法解析。')
def names(cert):return [v for k,v in decode_cert(cert).get('subjectAltName',[]) if k=='DNS']
def check_certificate(cert,key,hostname,seconds=0,trust=False):
    call(['openssl','x509','-in',cert,'-noout','-checkend',str(seconds)])
    host=hostname.lower().rstrip('.')
    dns=names(cert)
    def covers(pattern):
        pattern=pattern.lower().rstrip('.')
        return pattern==host or (pattern.startswith('*.') and not host.startswith('*.') and host.endswith(pattern[1:]) and len(host.split('.'))==len(pattern.split('.')))
    if not any(covers(pattern) for pattern in dns):raise Error('证书未覆盖该 SNI / 域名。')
    a=call(['openssl','x509','-in',cert,'-noout','-pubkey'])
    b=call(['openssl','pkey','-in',key,'-pubout'])
    if a.strip()!=b.strip():raise Error('证书与私钥不匹配。')
    if trust:call(['openssl','verify','-untrusted',cert,cert])
def cert_kind(cert):
    db=registry()
    for row in db.values():
        if str(cert)==row['cert']:return row['kind']
    details=decode_cert(cert)
    if details.get('issuer')==details.get('subject'):
        try:call(['openssl','verify','-check_ss_sig','-CAfile',cert,cert]);return 'self'
        except Error:pass
    return 'formal'
def matching_rows(host):
    rows=[]
    for rid,row in registry().items():
        try:check_certificate(row['cert'],row['key'],host,trust=row['kind']=='formal');rows.append((rid,row))
        except Exception:continue
    return rows

def public_key(private):
    raw=base64.urlsafe_b64decode(private+'='*((4-len(private)%4)%4))
    if len(raw)!=32:raise Error('Reality 私钥无效。')
    der=bytes.fromhex('302e020100300506032b656e04220420')+raw
    pub=call(['openssl','pkey','-inform','DER','-pubout','-outform','DER'],input=der)
    return base64.urlsafe_b64encode(pub[-32:]).decode().rstrip('=')
def geo(ip):
    path=ROOT/('country-'+hashlib.sha256(ip.encode()).hexdigest()[:16]+'.json')
    cache=read(path) if path.exists() else {}
    if cache.get('expires',0)>time.time():return cache.get('label','')
    for url,c,n in [('https://ipwho.is/'+ip,'country_code','country'),('https://ipapi.co/'+ip+'/json/','country_code','country_name'),('https://ipinfo.io/'+ip+'/json','country',None)]:
        try:
            obj=json.loads(call(['curl','-fLsS','--connect-timeout','2','--max-time','3',url],timeout=6));code=obj.get(c,'').upper()
            if obj.get('error') or obj.get('success') is False or not re.fullmatch('[A-Z]{2}',code):continue
            flag=''.join(chr(0x1f1e6+ord(ch)-65) for ch in code);label=flag+(obj.get(n) if n and isinstance(obj.get(n),str) else code)
            write(path,{'label':label,'expires':time.time()+86400});return label
        except Exception:pass
    label=cache.get('label','');write(path,{'label':label,'expires':time.time()+600});return label

def generate_links(cfg,meta,indices=None):
    """Called by both saved installers' sync workers; parameters come from JSON."""
    lines=[];is_alpine=alpine()
    for pos,i in enumerate(cfg.get('inbounds',[])):
        if indices is not None and pos not in indices:continue
        kind=i.get('type');tls=i.get('tls',{});reality=tls.get('reality',{}).get('enabled',False)
        if kind not in ('vless','hysteria2') or i.get('transport') or not tls.get('enabled'):raise Error('节点包含未支持的协议/传输，保留旧链接。')
        sni=domain(tls['server_name']);p=int(i['listen_port'])
        if not 1<=p<=65535:raise Error('监听端口错误。')
        if is_alpine:ip=meta.get('ipv4') or meta.get('ipv6')
        else:ip=meta.get('ipv6' if i.get('listen')=='::' else 'ipv4')
        if not ip:continue
        ip=str(ipaddress.ip_address(ip));host='['+ip+']' if ':' in ip else ip
        insecure='0'
        if not reality:
            ck=cert_kind(tls['certificate_path']);insecure='1' if ck=='self' else '0'
            if ck!='self':host=sni
        for u in i.get('users',[]):
            if kind=='vless':
                uid=str(uuid.UUID(u['uuid']));scheme='vless://';prefix='VLESS-Reality' if reality else 'VLESS-TLS'
                q={'type':'tcp','encryption':'none','security':'reality' if reality else 'tls','sni':sni}
                if reality:
                    ids=tls['reality'].get('short_id',[])
                    if not ids or not re.fullmatch('[a-fA-F0-9]{0,16}',ids[0]) or len(ids[0])%2:raise Error('Short ID 无效。')
                    q.update(fp='chrome',pbk=public_key(tls['reality']['private_key']),sid=ids[0])
                    if u.get('flow'):q['flow']=u['flow']
                elif is_alpine:q['insecure']=insecure
                else:q['allowInsecure']=insecure
            else:
                uid=urllib.parse.quote(u['password'],safe='');scheme='hysteria2://';prefix='HY2';q={'sni':sni,'insecure':insecure}
            family=ipaddress.ip_address(ip).version
            suffix=geo(ip);label=prefix+'-V'+str(family)+'PORT-'+host+('-'+suffix if suffix else '')
            lines.append(scheme+uid+'@'+host+':'+str(p)+'?'+urllib.parse.urlencode(q,quote_via=urllib.parse.quote)+'#'+urllib.parse.quote(label,safe=''))
    if not lines:raise Error('没有可生成的节点。')
    return '\n'.join(lines)+'\n'

# SYNC_SOURCE is populated at build time; no remote code needed for node management.
SYNC_SOURCE='IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJOb2RlIG1ldGFkYXRhIG9ubHk6IG5ldmVyIHJlc3RhcnRzIG9yIGVkaXRzIHNpbmctYm94IGNvbmZpZ3VyYXRpb24uIiIiCmltcG9ydCBiYXNlNjQsZmNudGwsaGFzaGxpYixpcGFkZHJlc3MsanNvbixvcyxwYXRobGliLHJlLHN1YnByb2Nlc3Msc3lzLHRlbXBmaWxlLHRpbWUsdXJsbGliLnBhcnNlLHV1aWQKU1RBVEU9cGF0aGxpYi5QYXRoKCcvdmFyL2xpYi9zaW5nYm94LW5vZGUtc3luYycpCkNPTkZJRz1wYXRobGliLlBhdGgoJy9ldGMvc2luZy1ib3gvY29uZmlnLmpzb24nKQpPVVRQVVQ9cGF0aGxpYi5QYXRoKCcvcm9vdC9zaW5nYm94X25vZGVzLnR4dCcpClNFQ09OREFSWT1wYXRobGliLlBhdGgoJy9ldGMvc2luZy1ib3gvdjJyYXluX2xpbmtzLnR4dCcpClJVTj1wYXRobGliLlBhdGgoJy9ydW4vc2luZ2JveC1ub2RlLXN5bmMnKQpkZWYgcnVuKGFyZ3MsKiprdyk6CiAgICByZXR1cm4gc3VicHJvY2Vzcy5ydW4oYXJncyxjaGVjaz1UcnVlLHN0ZG91dD1zdWJwcm9jZXNzLlBJUEUsc3RkZXJyPXN1YnByb2Nlc3MuREVWTlVMTCx0aW1lb3V0PTIwLCoqa3cpLnN0ZG91dApkZWYgcmVhZChwKTpyZXR1cm4ganNvbi5sb2FkcyhwYXRobGliLlBhdGgocCkucmVhZF90ZXh0KCkpCmRlZiBhdG9taWMocCxkYXRhKToKICAgIHA9cGF0aGxpYi5QYXRoKHApO3AucGFyZW50Lm1rZGlyKHBhcmVudHM9VHJ1ZSxleGlzdF9vaz1UcnVlKQogICAgZmQsbmFtZT10ZW1wZmlsZS5ta3N0ZW1wKHByZWZpeD0nLicrcC5uYW1lKyctJyxkaXI9cC5wYXJlbnQpCiAgICB0cnk6CiAgICAgICAgb3MuZmNobW9kKGZkLDBvNjAwKQogICAgICAgIHdpdGggb3MuZmRvcGVuKGZkLCd3YicpIGFzIGY6Zi53cml0ZShkYXRhLmVuY29kZSgpIGlmIGlzaW5zdGFuY2UoZGF0YSxzdHIpIGVsc2UgZGF0YSk7Zi5mbHVzaCgpO29zLmZzeW5jKGYuZmlsZW5vKCkpCiAgICAgICAgb3MucmVwbGFjZShuYW1lLHApCiAgICBmaW5hbGx5OgogICAgICAgIGlmIG9zLnBhdGguZXhpc3RzKG5hbWUpOm9zLnVubGluayhuYW1lKQpkZWYgd3JpdGUocCxkYXRhKTphdG9taWMocCxqc29uLmR1bXBzKGRhdGEsZW5zdXJlX2FzY2lpPUZhbHNlKSkKZGVmIGRpZ2VzdChkYXRhKTpyZXR1cm4gaGFzaGxpYi5zaGEyNTYoZGF0YSkuaGV4ZGlnZXN0KCkKZGVmIGNoZWNrZWRfY29uZmlnKCk6CiAgICBkYXRhPUNPTkZJRy5yZWFkX2J5dGVzKCk7Y2ZnPWpzb24ubG9hZHMoZGF0YSkKICAgIGJpbmFyeT1yZWFkKFNUQVRFLydkZXBsb3ltZW50Lmpzb24nKVsnYmluYXJ5J10KICAgIHJ1bihbYmluYXJ5LCdjaGVjaycsJy1jJyxzdHIoQ09ORklHKV0pCiAgICBpZiBDT05GSUcucmVhZF9ieXRlcygpIT1kYXRhOnJhaXNlIFJ1bnRpbWVFcnJvcign6YWN572u5qOA5p+l5pyf6Ze05Y+R55Sf5Y+Y5YyW77yM562J5b6F5LiL5qyh5qOA5p+lJykKICAgIHJldHVybiBkYXRhLGNmZwpkZWYgb3BlbnJjKCk6cmV0dXJuIHBhdGhsaWIuUGF0aCgnL2V0Yy9hbHBpbmUtcmVsZWFzZScpLmV4aXN0cygpCmRlZiBwcm9jZXNzKCk6CiAgICBpZiBvcGVucmMoKToKICAgICAgICBydW4oWydyYy1zZXJ2aWNlJywnc2luZy1ib3gnLCdzdGF0dXMnXSkKICAgICAgICBwaWQ9aW50KHJlYWQoUlVOLydhY3RpdmUuanNvbicpWydwaWQnXSkKICAgIGVsc2U6CiAgICAgICAgaWYgcnVuKFsnc3lzdGVtY3RsJywnaXMtYWN0aXZlJywnc2luZy1ib3guc2VydmljZSddKS5kZWNvZGUoKS5zdHJpcCgpIT0nYWN0aXZlJzpyYWlzZSBSdW50aW1lRXJyb3IoJ3NpbmctYm94IOacqui/kOihjCcpCiAgICAgICAgcGlkPWludChydW4oWydzeXN0ZW1jdGwnLCdzaG93Jywnc2luZy1ib3guc2VydmljZScsJy0tcHJvcGVydHk9TWFpblBJRCcsJy0tdmFsdWUnXSkuZGVjb2RlKCkuc3RyaXAoKSkKICAgIGlmIHBpZDw9MDpyYWlzZSBSdW50aW1lRXJyb3IoJ+aXoOazleehruiupCBzaW5nLWJveCBQSUQnKQogICAgcHJvYz1wYXRobGliLlBhdGgoJy9wcm9jJykvc3RyKHBpZCkKICAgIHRpY2tzPXByb2Muam9pbnBhdGgoJ3N0YXQnKS5yZWFkX3RleHQoKS5yc3BsaXQoJyknLDEpWzFdLnNwbGl0KClbMTldCiAgICBhcmdzPXByb2Muam9pbnBhdGgoJ2NtZGxpbmUnKS5yZWFkX2J5dGVzKCkuc3BsaXQoYidcMCcpCiAgICBpZiBiJy1jJyBub3QgaW4gYXJncyBvciBhcmdzW2FyZ3MuaW5kZXgoYictYycpKzFdIT1zdHIoQ09ORklHKS5lbmNvZGUoKTpyYWlzZSBSdW50aW1lRXJyb3IoJ+i/kOihjOi/m+eoi+mFjee9rui3r+W+hOS4jeWMuemFjScpCiAgICByZXR1cm4gcGlkLHRpY2tzCmRlZiBtYXJrKCk6CiAgICAjIEV4ZWNTdGFydFBvc3QgcnVucyB3aGlsZSB0aGUgdW5pdCBpcyBhY3RpdmF0aW5nLCBzbyBkbyBub3QgcmVxdWlyZSBpcy1hY3RpdmUgaGVyZS4KICAgIHBpZD1pbnQob3MuZW52aXJvbi5nZXQoJ01BSU5QSUQnLCcwJykpCiAgICBpZiBub3QgcGlkOnBpZD1pbnQocnVuKFsnc3lzdGVtY3RsJywnc2hvdycsJ3NpbmctYm94LnNlcnZpY2UnLCctLXByb3BlcnR5PU1haW5QSUQnLCctLXZhbHVlJ10pLmRlY29kZSgpLnN0cmlwKCkpCiAgICB0aWNrcz1wYXRobGliLlBhdGgoJy9wcm9jJyxzdHIocGlkKSwnc3RhdCcpLnJlYWRfdGV4dCgpLnJzcGxpdCgnKScsMSlbMV0uc3BsaXQoKVsxOV0KICAgIGRhdGE9KFJVTi8ncGVuZGluZy5qc29uJykucmVhZF9ieXRlcygpCiAgICBpZiBDT05GSUcucmVhZF9ieXRlcygpIT1kYXRhOnJhaXNlIFJ1bnRpbWVFcnJvcign5ZCv5Yqo5pyf6Ze06YWN572u5Y+R55Sf5Y+Y5YyW77yM6K+36YeN5paw5ZCv5Yqo5qC45b+DJykKICAgIHdyaXRlKFJVTi8nYWN0aXZlLmpzb24nLHsncGlkJzpwaWQsJ3RpY2tzJzp0aWNrcywnc2hhJzpkaWdlc3QoZGF0YSl9KQogICAgYXRvbWljKFJVTi8nbG9hZGVkLmpzb24nLGRhdGEpCmRlZiBjb3VudHJ5KGlwKToKICAgIHRyeTppcD1zdHIoaXBhZGRyZXNzLmlwX2FkZHJlc3MoaXApKQogICAgZXhjZXB0IFZhbHVlRXJyb3I6cmV0dXJuICcnCiAgICBwYXRoPVNUQVRFLygnY291bnRyeS0nK2RpZ2VzdChpcC5lbmNvZGUoKSlbOjE2XSsnLmpzb24nKTtub3c9dGltZS50aW1lKCkKICAgIGNhY2hlPXt9CiAgICB0cnk6Y2FjaGU9cmVhZChwYXRoKQogICAgZXhjZXB0IChPU0Vycm9yLFZhbHVlRXJyb3IpOnBhc3MKICAgIGlmIGNhY2hlLmdldCgnZXhwaXJlcycsMCk+bm93OnJldHVybiBjYWNoZS5nZXQoJ2xhYmVsJywnJykKICAgIHByb3ZpZGVycz1bKCdodHRwczovL2lwd2hvLmlzLycraXAsJ2NvdW50cnlfY29kZScsJ2NvdW50cnknKSwoJ2h0dHBzOi8vaXBhcGkuY28vJytpcCsnL2pzb24vJywnY291bnRyeV9jb2RlJywnY291bnRyeV9uYW1lJyksKCdodHRwczovL2lwaW5mby5pby8nK2lwKycvanNvbicsJ2NvdW50cnknLE5vbmUpXQogICAgZm9yIHVybCxjb2RlX2ZpZWxkLG5hbWVfZmllbGQgaW4gcHJvdmlkZXJzOgogICAgICAgIHRyeToKICAgICAgICAgICAgcmF3PXJ1bihbJ2N1cmwnLCctZkxzUycsJy0tY29ubmVjdC10aW1lb3V0JywnMicsJy0tbWF4LXRpbWUnLCczJyx1cmxdKQogICAgICAgICAgICBvYmo9anNvbi5sb2FkcyhyYXcpO2NvZGU9b2JqLmdldChjb2RlX2ZpZWxkLCcnKS51cHBlcigpCiAgICAgICAgICAgIGlmIG9iai5nZXQoJ3N1Y2Nlc3MnKSBpcyBGYWxzZSBvciBvYmouZ2V0KCdlcnJvcicpIG9yIG5vdCByZS5mdWxsbWF0Y2goJ1tBLVpdezJ9Jyxjb2RlKTpjb250aW51ZQogICAgICAgICAgICBmbGFnPScnLmpvaW4oY2hyKDB4MWYxZTYrb3JkKGMpLTY1KSBmb3IgYyBpbiBjb2RlKQogICAgICAgICAgICBuYW1lPW9iai5nZXQobmFtZV9maWVsZCkgaWYgbmFtZV9maWVsZCBlbHNlIGNvZGUKICAgICAgICAgICAgbGFiZWw9ZmxhZysobmFtZSBpZiBpc2luc3RhbmNlKG5hbWUsc3RyKSBhbmQgbmFtZSBlbHNlIGNvZGUpCiAgICAgICAgICAgIHdyaXRlKHBhdGgseydsYWJlbCc6bGFiZWwsJ2V4cGlyZXMnOm5vdys4NjQwMCwnaXAnOmlwfSk7cmV0dXJuIGxhYmVsCiAgICAgICAgZXhjZXB0IChWYWx1ZUVycm9yLE9TRXJyb3Isc3VicHJvY2Vzcy5TdWJwcm9jZXNzRXJyb3IsQXR0cmlidXRlRXJyb3IpOmNvbnRpbnVlCiAgICAjIEtlZXAgYW4gb2xkIHZhbGlkIGNvdW50cnkgd2hlbiBwcm92aWRlcnMgYXJlIHVuYXZhaWxhYmxlOyByZXRyeSBmYWlsdXJlcyBhZnRlciAxMCBtaW51dGVzLgogICAgbGFiZWw9Y2FjaGUuZ2V0KCdsYWJlbCcsJycpO3dyaXRlKHBhdGgseydsYWJlbCc6bGFiZWwsJ2V4cGlyZXMnOm5vdys2MDAsJ2lwJzppcH0pO3JldHVybiBsYWJlbApkZWYgaXBfZm9yKHRhZyxtZXRhKToKICAgIHByZWZlcnJlZD0naXB2NicgaWYgJ1Y2JyBpbiB0YWcgZWxzZSAnaXB2NCcKICAgIHJldHVybiBtZXRhLmdldChwcmVmZXJyZWQpIG9yIG1ldGEuZ2V0KCdpcHY2JyBpZiBwcmVmZXJyZWQ9PSdpcHY0JyBlbHNlICdpcHY0Jykgb3IgJycKZGVmIG5vZGVfbmFtZShuYW1lLGlwKToKICAgIHN1ZmZpeD1jb3VudHJ5KGlwKQogICAgcmV0dXJuIHVybGxpYi5wYXJzZS5xdW90ZShuYW1lKygnLScrc3VmZml4IGlmIHN1ZmZpeCBlbHNlICcnKSxzYWZlPScnKQpkZWYgcHVibGljX2tleShwcml2YXRlKToKICAgIHJhdz1iYXNlNjQudXJsc2FmZV9iNjRkZWNvZGUocHJpdmF0ZSsnPScqKCg0LWxlbihwcml2YXRlKSU0KSU0KSkKICAgIGlmIGxlbihyYXcpIT0zMjpyYWlzZSBSdW50aW1lRXJyb3IoJ1JlYWxpdHkg56eB6ZKl6ZW/5bqm6ZSZ6K+vJykKICAgIGRlcj1ieXRlcy5mcm9taGV4KCczMDJlMDIwMTAwMzAwNTA2MDMyYjY1NmUwNDIyMDQyMCcpK3JhdwogICAgcHViPXJ1bihbJ29wZW5zc2wnLCdwa2V5JywnLWluZm9ybScsJ0RFUicsJy1wdWJvdXQnLCctb3V0Zm9ybScsJ0RFUiddLGlucHV0PWRlcikKICAgIGlmIGxlbihwdWIpIT00NCBvciBwdWJbOjEyXSE9Ynl0ZXMuZnJvbWhleCgnMzAyYTMwMDUwNjAzMmI2NTZlMDMyMTAwJyk6cmFpc2UgUnVudGltZUVycm9yKCfml6Dms5Xop6PmnpAgUmVhbGl0eSDlhazpkqUnKQogICAgcmV0dXJuIGJhc2U2NC51cmxzYWZlX2I2NGVuY29kZShwdWJbLTMyOl0pLmRlY29kZSgpLnJzdHJpcCgnPScpCmRlZiBsaXN0ZW5zKHBpZCxjZmcpOgogICAgaW5vZGVzPXNldCgpCiAgICBmb3IgZmQgaW4gcGF0aGxpYi5QYXRoKCcvcHJvYycsc3RyKHBpZCksJ2ZkJykuaXRlcmRpcigpOgogICAgICAgIHRyeToKICAgICAgICAgICAgdGFyZ2V0PW9zLnJlYWRsaW5rKGZkKQogICAgICAgICAgICBpZiB0YXJnZXQuc3RhcnRzd2l0aCgnc29ja2V0OlsnKTppbm9kZXMuYWRkKHRhcmdldFs4Oi0xXSkKICAgICAgICBleGNlcHQgT1NFcnJvcjpwYXNzCiAgICBhdmFpbGFibGU9c2V0KCkKICAgIGZvciB0YWJsZSBpbiBbJ3RjcCcsJ3RjcDYnLCd1ZHAnLCd1ZHA2J106CiAgICAgICAgdHJ5OnJvd3M9cGF0aGxpYi5QYXRoKCcvcHJvYycsc3RyKHBpZCksJ25ldCcsdGFibGUpLnJlYWRfdGV4dCgpLnNwbGl0bGluZXMoKVsxOl0KICAgICAgICBleGNlcHQgT1NFcnJvcjpjb250aW51ZQogICAgICAgIGZvciByb3cgaW4gcm93czoKICAgICAgICAgICAgZmllbGRzPXJvdy5zcGxpdCgpCiAgICAgICAgICAgIGlmIGxlbihmaWVsZHMpPDEwIG9yIGZpZWxkc1s5XSBub3QgaW4gaW5vZGVzOmNvbnRpbnVlCiAgICAgICAgICAgIGlmIHRhYmxlLnN0YXJ0c3dpdGgoJ3RjcCcpIGFuZCBmaWVsZHNbM10hPScwQSc6Y29udGludWUKICAgICAgICAgICAgYXZhaWxhYmxlLmFkZCgoJ3RjcCcgaWYgdGFibGUuc3RhcnRzd2l0aCgndGNwJykgZWxzZSAndWRwJyxpbnQoZmllbGRzWzFdLnNwbGl0KCc6JylbLTFdLDE2KSkpCiAgICBmb3IgaW5ib3VuZCBpbiBjZmcuZ2V0KCdpbmJvdW5kcycsW10pOgogICAgICAgIGtpbmQ9aW5ib3VuZC5nZXQoJ3R5cGUnKQogICAgICAgIGlmIGtpbmQgbm90IGluIFsndmxlc3MnLCdoeXN0ZXJpYTInXTpyYWlzZSBSdW50aW1lRXJyb3IoJ+WHuueOsOmdnuWOn+iEmuacrOaUr+aMgeeahOWFpeerme+8jOacquimhuebluiKgueCueaWh+S7ticpCiAgICAgICAgcHJvdG9jb2w9J3VkcCcgaWYga2luZD09J2h5c3RlcmlhMicgZWxzZSAndGNwJwogICAgICAgIHBvcnQ9aW5ib3VuZC5nZXQoJ2xpc3Rlbl9wb3J0JykKICAgICAgICBpZiBub3QgaXNpbnN0YW5jZShwb3J0LGludCkgb3Igbm90IDE8PXBvcnQ8PTY1NTM1IG9yIChwcm90b2NvbCxwb3J0KSBub3QgaW4gYXZhaWxhYmxlOnJhaXNlIFJ1bnRpbWVFcnJvcign5YWl56uZ56uv5Y+j5bCa5pyq55Sx5b2T5YmN5qC45b+D55uR5ZCsJykKZGVmIGdlbmVyYXRlKGNmZyxtZXRhKToKICAgIGltcG9ydCBydW5weQogICAgcmV0dXJuIHJ1bnB5LnJ1bl9wYXRoKCcvdXNyL2xvY2FsL2xpYi9hcmdvLXN0YW5kYWxvbmUvbWFuYWdlci5weScscnVuX25hbWU9J2FyZ29fZ2VuZXJhdG9yJylbJ2dlbmVyYXRlX2xpbmtzJ10oY2ZnLG1ldGEpCgpkZWYgc3luYygpOgogICAgcGlkLHRpY2tzPXByb2Nlc3MoKTthY3RpdmU9cmVhZChSVU4vJ2FjdGl2ZS5qc29uJykKICAgIGRhdGEsY2ZnPWNoZWNrZWRfY29uZmlnKCkKICAgIGlmIGFjdGl2ZSE9eydwaWQnOnBpZCwndGlja3MnOnRpY2tzLCdzaGEnOmRpZ2VzdChkYXRhKX0gb3IgKFJVTi8nbG9hZGVkLmpzb24nKS5yZWFkX2J5dGVzKCkhPWRhdGE6cmFpc2UgUnVudGltZUVycm9yKCfno4Hnm5jphY3nva7mnKrnoa7orqTlt7LliqDovb3vvIzor7fmo4Dmn6XphY3nva7lkI7ph43lkK8gc2luZy1ib3gnKQogICAgbGlzdGVucyhwaWQsY2ZnKQogICAgY29udGVudD1nZW5lcmF0ZShjZmcscmVhZChTVEFURS8nZGVwbG95bWVudC5qc29uJykpCiAgICAjIFNsb3cgZ2VvbG9jYXRpb24gbXVzdCBub3QgYWxsb3cgYSBzZXJ2aWNlIHJlc3RhcnQgb3IgY29uZmlnIGVkaXQgdG8gcmFjZSB0aGUgd3JpdGUuCiAgICBpZiBwcm9jZXNzKCkhPShwaWQsdGlja3MpIG9yIENPTkZJRy5yZWFkX2J5dGVzKCkhPWRhdGEgb3IgcmVhZChSVU4vJ2FjdGl2ZS5qc29uJykhPWFjdGl2ZTpyYWlzZSBSdW50aW1lRXJyb3IoJ+eUn+aIkOacn+mXtOmFjee9ruaIlui/m+eoi+aUueWPmO+8jOS/neeVmeaXp+aWh+S7ticpCiAgICBpZiBub3QgT1VUUFVULmV4aXN0cygpIG9yIE9VVFBVVC5yZWFkX3RleHQoKSE9Y29udGVudDoKICAgICAgICBhdG9taWMoT1VUUFVULGNvbnRlbnQpO3ByaW50KHRpbWUuc3RyZnRpbWUoJyVZLSVtLSVkVCVIOiVNOiVTWicsdGltZS5nbXRpbWUoKSkrJyDoioLngrnmlofku7blt7Lmm7TmlrAnLGZsdXNoPVRydWUpCiAgICBpZiBub3QgU0VDT05EQVJZLmV4aXN0cygpIG9yIFNFQ09OREFSWS5yZWFkX3RleHQoKSE9Y29udGVudDphdG9taWMoU0VDT05EQVJZLGNvbnRlbnQpCmRlZiBtYWluKCk6CiAgICBTVEFURS5ta2RpcihwYXJlbnRzPVRydWUsZXhpc3Rfb2s9VHJ1ZSk7UlVOLm1rZGlyKHBhcmVudHM9VHJ1ZSxleGlzdF9vaz1UcnVlKQogICAgb3MuY2htb2QoU1RBVEUsMG83MDApO29zLmNobW9kKFJVTiwwbzcwMCkKICAgIHdpdGggb3BlbihSVU4vJ2xvY2snLCdhJykgYXMgbG9jazoKICAgICAgICBmY250bC5mbG9jayhsb2NrLGZjbnRsLkxPQ0tfRVgpCiAgICAgICAgbW9kZT1zeXMuYXJndlsxXSBpZiBsZW4oc3lzLmFyZ3YpPjEgZWxzZSAnLS1vbmNlJwogICAgICAgIGlmIG1vZGU9PSctLWxhdW5jaCc6CiAgICAgICAgICAgIGRhdGEsY2ZnPWNoZWNrZWRfY29uZmlnKCk7YXRvbWljKFJVTi8ncGVuZGluZy5qc29uJyxkYXRhKQogICAgICAgICAgICBvcy5lbnZpcm9uWydNQUlOUElEJ109c3RyKG9zLmdldHBpZCgpKTttYXJrKCkKICAgICAgICAgICAgYmluYXJ5PXJlYWQoU1RBVEUvJ2RlcGxveW1lbnQuanNvbicpWydiaW5hcnknXQogICAgICAgICAgICAjIFJlbGVhc2UgdGhlIHN5bmMgbG9jayBiZWZvcmUgcmVwbGFjaW5nIHRoaXMgcHJvY2VzcyB3aXRoIHRoZSBjb3JlLgogICAgICAgICAgICBmY250bC5mbG9jayhsb2NrLGZjbnRsLkxPQ0tfVU4pO2xvY2suY2xvc2UoKQogICAgICAgICAgICBvcy5leGVjdihiaW5hcnksW2JpbmFyeSwncnVuJywnLWMnLHN0cihDT05GSUcpXSkKICAgICAgICBlbGlmIG1vZGU9PSctLWNhcHR1cmUnOmRhdGEsY2ZnPWNoZWNrZWRfY29uZmlnKCk7YXRvbWljKFJVTi8ncGVuZGluZy5qc29uJyxkYXRhKQogICAgICAgIGVsaWYgbW9kZT09Jy0tbWFyayc6bWFyaygpCiAgICAgICAgZWxpZiBtb2RlPT0nLS1sYWJlbCc6cHJpbnQobm9kZV9uYW1lKHN5cy5hcmd2WzJdLHN5cy5hcmd2WzNdKSkKICAgICAgICBlbGlmIG1vZGU9PSctLW9uY2UnOnN5bmMoKQogICAgICAgIGVsc2U6cmFpc2UgUnVudGltZUVycm9yKCfmnKrnn6Xov5DooYzlj4LmlbAnKQppZiBfX25hbWVfXz09J19fbWFpbl9fJzoKICAgIHRyeToKICAgICAgICBpZiBsZW4oc3lzLmFyZ3YpPjEgYW5kIHN5cy5hcmd2WzFdPT0nLS13YXRjaCc6CiAgICAgICAgICAgIHN5cy5hcmd2WzFdPSctLW9uY2UnCiAgICAgICAgICAgIHdoaWxlIFRydWU6CiAgICAgICAgICAgICAgICB0cnk6bWFpbigpCiAgICAgICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgICAgICAgICAgICAgcHJpbnQodGltZS5zdHJmdGltZSgnJVktJW0tJWRUJUg6JU06JVNaJyx0aW1lLmdtdGltZSgpKSsnIOWQjOatpeacquWujOaIkO+8jOS/neeVmeaXp+aWh+S7tu+8micrKHN0cihlKSBpZiBpc2luc3RhbmNlKGUsUnVudGltZUVycm9yKSBlbHNlIHR5cGUoZSkuX19uYW1lX18pLGZpbGU9c3lzLnN0ZGVycixmbHVzaD1UcnVlKQogICAgICAgICAgICAgICAgdGltZS5zbGVlcCg2MCkKICAgICAgICBlbHNlOm1haW4oKQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICMgRG8gbm90IHByaW50IEpTT04sIHBhc3N3b3JkcywgcHJpdmF0ZSBrZXlzLCBvciBjb21wbGV0ZSBVUklzIHRvIHNlcnZpY2UgbG9ncy4KICAgICAgICBwcmludCh0aW1lLnN0cmZ0aW1lKCclWS0lbS0lZFQlSDolTTolU1onLHRpbWUuZ210aW1lKCkpKycg5ZCM5q2l5aSx6LSl77yI5L+d55WZ5pen5paH5Lu277yJ77yaJyt0eXBlKGUpLl9fbmFtZV9fKycgJysoc3RyKGUpIGlmIGlzaW5zdGFuY2UoZSxSdW50aW1lRXJyb3IpIGVsc2UgJ+ivt+ajgOafpemFjee9ruOAgeS+nei1luWPiuadg+mZkCcpLGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBzeXMuZXhpdCgxKQo='
def verify_service_config():
    if active():
        if alpine():
            pidpaths=[RUN/'active.json',pathlib.Path('/run/sing-box.pid')]
            pid=0
            for path in pidpaths:
                try:
                    candidate=int(read(path)['pid']) if path.suffix=='.json' else int(path.read_text().strip())
                    args=pathlib.Path('/proc',str(candidate),'cmdline').read_bytes().split(b'\0')
                    if b'-c' in args and args[args.index(b'-c')+1]==str(CONFIG).encode():pid=candidate;break
                except Exception:continue
            if not pid:raise Error('不能确认运行服务使用此配置文件，未修改服务。')
        else:
            pid=int(call(['systemctl','show','sing-box.service','--property=MainPID','--value']).strip())
            args=pathlib.Path('/proc',str(pid),'cmdline').read_bytes().split(b'\0')
            if b'-c' not in args or args[args.index(b'-c')+1]!=str(CONFIG).encode():raise Error('sing-box 服务使用其它配置路径，未修改。')
    else:
        if alpine():
            script=pathlib.Path('/etc/init.d/sing-box').read_text()
            if str(CONFIG) not in script and '--launch' not in script:raise Error('服务配置路径不匹配。')
        elif str(CONFIG) not in call(['systemctl','show','sing-box.service','--property=ExecStart','--value']).decode():raise Error('服务配置路径不匹配。')

@locked
def initialize_sync():
    cfg=config();core=binary();verify_service_config();LIB.mkdir(parents=True,exist_ok=True);os.chmod(LIB,0o700)
    atomic(SYNC,base64.b64decode(SYNC_SOURCE),0o700)
    if not META.exists():
        ips={}
        for family in ('4','6'):
            for url in ('https://api64.ipify.org','https://ifconfig.co/ip'):
                try:
                    address=call(['curl','-'+family,'-fLsS','--max-time','4',url],timeout=6).decode().strip();ips['ipv'+family]=str(ipaddress.ip_address(address));break
                except Exception:pass
        if not ips:raise Error('无法检测公网 IP，不能生成节点链接。')
        META.parent.mkdir(parents=True,exist_ok=True);os.chmod(META.parent,0o700);write(META,dict(ips,binary=core,mode='2',domain=''))
    patched=False
    for path in (pathlib.Path('/usr/local/lib/singbox-node-sync/run'),pathlib.Path('/usr/local/lib/alpine-node-sync/run')):
        if not path.exists():continue
        source=path.read_text()
        if 'def generate(cfg,meta):' not in source or "'/run/singbox-node-sync'" not in source:raise Error('检测到未知节点同步程序，未改动它。')
        if '# ARGO_CERT_GENERATOR' not in source:
            backup=path.with_name(path.name+'.before-cert-manager')
            if not backup.exists():atomic(backup,source,0o700)
            prefix="def generate(cfg,meta):\n    # ARGO_CERT_GENERATOR\n    import runpy\n    return runpy.run_path('/usr/local/lib/argo-standalone/manager.py',run_name='argo_generator')['generate_links'](cfg,meta)\n"
            atomic(path,source.replace('def generate(cfg,meta):\n',prefix,1),0o700)
        patched=True
    current_meta=read(META)
    if current_meta.get('binary')!=core:current_meta['binary']=core;write(META,current_meta)
    if patched:return
    if alpine() and RC_CORE.exists() and RC_SYNC.exists() and str(SYNC) in RC_CORE.read_text():return
    # Original installers without a sync worker: add startup snapshots and a timer.
    if alpine():configure_openrc_sync()
    else:
        atomic('/etc/systemd/system/sing-box.service.d/argo-node-sync.conf',f'[Service]\nExecStartPre={SYNC} --capture\nExecStartPost={SYNC} --mark\n')
        atomic('/etc/systemd/system/argo-sb-sync.service',f'[Unit]\nAfter=sing-box.service\n[Service]\nType=oneshot\nExecStart={SYNC} --once\nUMask=0077\nTimeoutStartSec=180\n')
        atomic('/etc/systemd/system/argo-sb-sync.timer','[Timer]\nOnBootSec=45s\nOnUnitActiveSec=60s\n[Install]\nWantedBy=timers.target\n')
        call(['systemctl','daemon-reload']);call(['systemctl','enable','--now','argo-sb-sync.timer'])
@locked
def configure_openrc_sync():
    old=RC_CORE.read_bytes() if RC_CORE.exists() else None
    oldsync=RC_SYNC.read_bytes() if RC_SYNC.exists() else None
    backup=RC_CORE.with_name('sing-box.before-argo-cert-manager')
    if old is not None and not backup.exists():atomic(backup,old,0o755)
    was=active()
    # Stop with the original service file and PID format, before switching supervisor.
    if was:service('stop')
    try:
        atomic(RC_CORE,textwrap.dedent(f'''\
        #!/sbin/openrc-run
        name="sing-box"
        supervisor="supervise-daemon"
        command="{SYNC}"
        command_args="--launch"
        pidfile="/run/sing-box.supervisor.pid"
        respawn_delay=2
        respawn_max=0
        respawn_period=60
        output_log="/var/log/sing-box/argo-core.log"
        error_log="/var/log/sing-box/argo-core.log"
        depend() {{ need net; }}
        '''),0o755)
        atomic(RC_SYNC,textwrap.dedent(f'''\
        #!/sbin/openrc-run
        name="argo sing-box link sync"
        supervisor="supervise-daemon"
        command="{SYNC}"
        command_args="--watch"
        pidfile="/run/argo-sb-sync.pid"
        respawn_delay=5
        respawn_max=0
        respawn_period=60
        output_log="/var/log/sing-box/node-sync.log"
        error_log="/var/log/sing-box/node-sync.log"
        depend() {{ need net; after sing-box; }}
        '''),0o755)
        call(['rc-update','add','sing-box','default'])
        if was:service('start');time.sleep(2)
        call(['rc-update','add','argo-sb-sync','default']);call(['rc-service','argo-sb-sync','restart'])
    except Exception:
        try:call(['rc-service','argo-sb-sync','stop'])
        except Exception:pass
        try:service('stop')
        except Exception:pass
        if old is None:
            if RC_CORE.exists():RC_CORE.unlink()
        else:atomic(RC_CORE,old,0o755)
        if oldsync is None:
            try:call(['rc-update','del','argo-sb-sync','default'])
            except Exception:pass
            if RC_SYNC.exists():RC_SYNC.unlink()
        else:atomic(RC_SYNC,oldsync,0o755)
        if was:
            try:service('start')
            except Exception:say('⚠ 原服务文件已恢复，但服务启动失败。','warn')
        raise Error('OpenRC 接入未完成，原服务文件已恢复。')

def sync_now(strict=True):
    deadline=time.monotonic()+(45 if strict else 0)
    while True:
        try:call([SYNC,'--once'],timeout=180);return
        except Exception:
            if not strict:
                say('⚠ 自检未通过，下面显示上次保存的信息。','warn');return
            if time.monotonic()>=deadline:raise Error('节点链接验证失败，未发布新的节点。')
            time.sleep(2)
def check_config_bytes(data):
    with tempfile.TemporaryDirectory(dir=CONFIG.parent) as tmp:
        candidate=pathlib.Path(tmp)/'config.json';atomic(candidate,data)
        call([binary(),'check','-c',candidate])
@locked
def commit_config(new,old):
    data=(json.dumps(new,ensure_ascii=False,indent=2)+'\n').encode();check_config_bytes(data)
    for i in new.get('inbounds',[]):
        tls=i.get('tls',{})
        if tls.get('enabled') and not tls.get('reality',{}).get('enabled'):
            check_certificate(tls['certificate_path'],tls['key_path'],tls['server_name'],trust=cert_kind(tls['certificate_path'])=='formal')
    if CONFIG.is_symlink():raise Error('配置是符号链接，未覆盖。')
    if CONFIG.read_bytes()!=old:raise Error('配置被其他程序修改，请重新进入。')
    links={path:path.read_bytes() if path.exists() else None for path in LINKFILES}
    was=active();backup=ROOT/'backups'/('config-'+str(time.time_ns())+'.json');atomic(backup,old)
    try:
        atomic(CONFIG,data);service('restart');time.sleep(2);sync_now()
    except BaseException as failure:
        atomic(CONFIG,old)
        try:service('restart' if was else 'stop')
        except Exception:say('⚠ 旧配置已恢复，但服务恢复失败，请查看日志。','warn')
        sync_now(False) if was else None
        for path,content in links.items():
            if content is None:
                if path.exists():path.unlink()
            else:atomic(path,content)
        if isinstance(failure,KeyboardInterrupt):raise failure
        raise Error('修改未完成，已恢复旧配置和旧节点参数。')
    say('✓ 配置已生效，节点信息已更新。','ok')

# ---------- Certificate clients ----------
def fetch(url,out):call(['curl','-fLsS','--retry','2','--connect-timeout','10','--max-time','180',url,'-o',out],timeout=400)
def install_acme():
    path=LIB/'acme/acme.sh';path.parent.mkdir(parents=True,exist_ok=True);os.chmod(path.parent,0o700)
    plugin=path.parent/'dnsapi/dns_cf.sh';plugin.parent.mkdir(exist_ok=True)
    for dest,url in [(path,'https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh'),(plugin,'https://raw.githubusercontent.com/acmesh-official/acme.sh/master/dnsapi/dns_cf.sh')]:
        if dest.exists():continue
        with tempfile.TemporaryDirectory(dir=path.parent) as tmp:
            stage=pathlib.Path(tmp)/dest.name;fetch(url,stage);call(['sh','-n',stage]);atomic(dest,stage.read_bytes(),0o700)
    return path

def install_lego():
    path=LIB/'lego'
    if path.exists():call([path,'--version']);return path
    arch={'x86_64':'amd64','aarch64':'arm64','arm64':'arm64'}.get(os.uname().machine)
    if not arch:raise Error('备用程序仅支持 AMD64 / ARM64。')
    with tempfile.TemporaryDirectory() as tmp:
        tmp=pathlib.Path(tmp);fetch('https://api.github.com/repos/go-acme/lego/releases/latest',tmp/'release.json');info=read(tmp/'release.json')
        asset=next((a for a in info['assets'] if a['name'].endswith('linux_'+arch+'.tar.gz')),None)
        if not asset:raise Error('未找到 lego 对应架构。')
        fetch(asset['browser_download_url'],tmp/'lego.tgz');expected=asset.get('digest','')
        if not expected.startswith('sha256:'):
            checksum=next((a for a in info['assets'] if 'checksums' in a['name'].lower()),None)
            if not checksum:raise Error('没有 lego 下载校验信息。')
            fetch(checksum['browser_download_url'],tmp/'checksums')
            expected=next(('sha256:'+line.split()[0] for line in (tmp/'checksums').read_text().splitlines() if line.split()[-1].lstrip('*')==asset['name']),'')
        if expected!='sha256:'+hashlib.sha256((tmp/'lego.tgz').read_bytes()).hexdigest():raise Error('lego 下载校验失败。')
        with tarfile.open(tmp/'lego.tgz') as tar:
            member=next((m for m in tar.getmembers() if pathlib.PurePosixPath(m.name).name=='lego' and m.isfile()),None)
            if not member:raise Error('lego 压缩包中没有程序。')
            atomic(path,tar.extractfile(member).read(),0o700)
    call([path,'--version']);return path

def cf_credentials(host):
    saved=read(ROOT/'dns-auth.json') if (ROOT/'dns-auth.json').exists() else {}
    source=pathlib.Path('/etc/vps-cf-api/auth.json')
    if source.exists() and confirm('复用已接入的 Cloudflare API 凭据？'):
        saved=read(source)
    else:
        token=prompt('Cloudflare API Token（DNS 编辑、Zone 读取；留空保留已存凭据）',secret=True)
        if token:saved={'token':token,'account_id':prompt('Account ID（可留空）'),'zone_id':prompt('Zone ID（可留空）')}
    if not saved.get('token'):raise Error('未提供 DNS API Token。')
    def cf_get(path):
        request=urllib.request.Request('https://api.cloudflare.com/client/v4'+path,headers={'Authorization':'Bearer '+saved['token']})
        with urllib.request.urlopen(request,timeout=20) as response:result=json.load(response)
        if not result.get('success'):raise Error('Cloudflare API 读取验证失败。')
        return result['result']
    zone=None;labels=host.removeprefix('*.').split('.')
    for offset in range(len(labels)-1):
        name='.'.join(labels[offset:])
        try:
            rows=cf_get('/zones?name='+urllib.parse.quote(name)+'&per_page=50')
            if rows:zone=rows[0];break
        except Exception:continue
    if not zone:raise Error('无法读取该域名的 Cloudflare 区域，请检查 Token 的 Zone 读取权限和域名范围；未覆盖旧凭据。')
    saved.update(zone_id=zone['id'],account_id=zone['account']['id'],zone_name=zone['name'])
    write(ROOT/'dns-auth.json',saved)
    say('✓ 域名区域读取通过；DNS 编辑权限将在签发时检查。','ok')
    return saved

def cert_environment(row):
    env=os.environ.copy()
    for name in ('CF_Key','CF_Email','CF_Token','CF_Account_ID','CF_Zone_ID','CF_DNS_API_TOKEN','CF_ZONE_API_TOKEN','CLOUDFLARE_API_KEY','CLOUDFLARE_API_EMAIL','CLOUDFLARE_DNS_API_TOKEN','CLOUDFLARE_ZONE_API_TOKEN'):env.pop(name,None)
    if row['method']=='dns':
        auth=read(row.get('auth_file',ROOT/'dns-auth.json'));token=auth['token']
        env.update(CF_Token=token,CF_DNS_API_TOKEN=token,CF_ZONE_API_TOKEN=token)
        if auth.get('account_id'):env['CF_Account_ID']=auth['account_id']
        if auth.get('zone_id'):env['CF_Zone_ID']=auth['zone_id']
    return env

def http_check(row):
    if row['method']!='http':return
    if row['domain'].startswith('*.'):raise Error('通配符证书必须使用 DNS 验证。')
    try:
        for ip in {a[4][0] for a in socket.getaddrinfo(row['domain'],80,type=socket.SOCK_STREAM)}:ipaddress.ip_address(ip)
    except Exception:raise Error('域名无法解析，请先设置 A / AAAA 记录。')
    for family,host in [(socket.AF_INET,'0.0.0.0'),(socket.AF_INET6,'::')]:
        with socket.socket(family,socket.SOCK_STREAM) as s:
            if family==socket.AF_INET6:
                try:s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1)
                except OSError:continue
            try:s.bind((host,80))
            except OSError as e:
                if e.errno in (97,99):continue
                raise Error('80 端口被占用或无法绑定；请选择 DNS 验证。')

def lego_command(exe,home,row,renew=False):
    version=call([exe,'--version']).decode()
    match=re.search(r'(?:version\s*:?\s*|^v?)(\d+)\.',version,re.I|re.M)
    if not match:raise Error('无法识别 lego 版本，未发起证书申请。')
    major=int(match.group(1))
    if major not in (4,5):raise Error('尚未适配此 lego 主版本，未发起申请。')
    common=['--path',str(home),'--email',row['email'],'--accept-tos','--domains',row['domain']]
    if row['method'] in ('dns','dns-manual'):common+=['--dns','manual' if row['method']=='dns-manual' else 'cloudflare']
    else:common+=['--http','--http.address' if major==5 else '--http.port',':80']
    if major==5:
        helptext=call([exe,'run','--help']).decode()
        required=['--path','--email','--domains','--accept-tos','--dns' if row['method'] in ('dns','dns-manual') else '--http']
        if not all(flag in helptext for flag in required):raise Error('lego run 参数不匹配，未发起申请。')
        # Legacy data can only be migrated by lego itself; preserve a private backup first.
        if any((home/'accounts').glob('*/*/keys')):
            backup=home.with_name(home.name+'-before-v5-'+str(time.time_ns()))
            shutil.copytree(home,backup);os.chmod(backup,0o700)
            call([exe,'migrate','--path',str(home)],timeout=120)
        return [str(exe),'run']+common+(['--renew-force','--no-random-sleep'] if renew and row['method']=='dns-manual' else ['--renew-days','30'] if renew else [])
    return [str(exe)]+common+(['renew','--days','3650' if row['method']=='dns-manual' else '30'] if renew else ['run'])

@locked
def client_issue(row,renew=False):
    home=pathlib.Path(row['client_home']) if row.get('client_home') else ROOT/'clients'/row['id']/row['client'];home.mkdir(parents=True,exist_ok=True);os.chmod(home,0o700)
    export=home/'export';export.mkdir(exist_ok=True);env=cert_environment(row);log=ROOT/'logs'/(row['id']+'.log')
    http_check(row);say('正在'+('续签' if renew else '申请')+'：'+row['domain']+' / '+row['client']) if sys.stdin.isatty() else None
    if row['client']=='acme.sh':
        exe=install_acme();base=['sh',exe,'--home',exe.parent,'--config-home',home,'--server','letsencrypt']
        if row['method']=='dns-manual':
            if not sys.stdin.isatty():raise Error('手动 DNS-01 需要交互终端。')
            flag='--yes-I-know-dns-manual-mode-enough-go-ahead-please'
            phase=['--renew','-d',row['domain'],'--ecc','--force',flag] if renew else ['--issue','-d',row['domain'],'--dns','--keylength','ec-256','--accountemail',row['email'],flag]
            result=managed_run([str(a) for a in base+phase],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=900)
            output=result.stdout.decode(errors='replace')
            print(output,flush=True)
            challenge='_acme-challenge' in output and 'TXT' in output
            if challenge:
                say('请添加上方列出的 TXT 名称和值；等待 DNS 生效后继续。','warn')
                if not confirm('TXT 已添加并生效，继续验证？'):raise Cancel()
                call(base+['--renew','-d',row['domain'],'--ecc',flag]+(['--force'] if renew else []),timeout=900,env=env,log=log)
            elif result.returncode:
                raise Error('未生成可用 TXT 挑战；请检查上方 acme.sh 错误。')
            call(base+['--install-cert','-d',row['domain'],'--ecc','--fullchain-file',export/'fullchain.pem','--key-file',export/'privkey.pem','--reloadcmd','true'],timeout=60,env=env,log=log)
            return export/'fullchain.pem',export/'privkey.pem'
        if renew:
            call(base+['--renew','-d',row['domain'],'--ecc'],timeout=900,env=env,log=log,allowed=(0,2))
        else:
            args=['--issue','-d',row['domain'],'--keylength','ec-256','--accountemail',row['email']]
            args+=['--dns','dns_cf'] if row['method']=='dns' else ['--standalone']
            call(base+args,timeout=900,env=env,log=log,allowed=(0,2))
        call(base+['--install-cert','-d',row['domain'],'--ecc','--fullchain-file',export/'fullchain.pem','--key-file',export/'privkey.pem','--reloadcmd','true'],timeout=60,env=env,log=log)
        return export/'fullchain.pem',export/'privkey.pem'
    if row['method']=='dns-manual':
        if row['client']!='lego':raise Error('手动 DNS-01 当前使用 lego。')
        if not sys.stdin.isatty():raise Error('手动 DNS-01 需要交互终端，不能后台自动续签。')
        exe=install_lego()
        say('请按下方提示在 DNS 控制台添加 TXT 记录。','warn')
        say('主机记录通常为 _acme-challenge；完整名称和值以 lego 显示为准。','dim')
        say('等待 DNS 生效后再按回车；验证成功前保留 TXT，Ctrl+C 可取消。','dim')
        args=lego_command(exe,home,row,renew)
        result=managed_run(args,env=env)
        if result.returncode:raise Error('lego 申请未完成，旧证书与节点配置保持不变；请根据上方错误检查程序参数、网络或 TXT 后重试。')
        filename=row['domain'].replace('*','_')
        return home/'certificates'/(filename+'.crt'),home/'certificates'/(filename+'.key')
    exe=install_lego();args=lego_command(exe,home,row,renew)
    call(args,timeout=900,env=env,log=log)
    filename=row['domain'].replace('*','_');return home/'certificates'/(filename+'.crt'),home/'certificates'/(filename+'.key')

def row_paths(row):
    directory=ROOT/'certs'/row['id'];return directory,directory/'current'
def switch_current(current,target):
    temp=current.with_name('.current-'+secrets.token_hex(4));os.symlink(str(target),temp);os.replace(temp,current)
@locked
def publish_certificate(row,cert,key):
    check_certificate(cert,key,row['domain'],trust=row['kind']=='formal')
    folder,current=row_paths(row);folder.mkdir(parents=True,exist_ok=True);os.chmod(folder,0o700)
    generation=folder/('generation-'+str(time.time_ns()));generation.mkdir(mode=0o700)
    atomic(generation/'fullchain.pem',pathlib.Path(cert).read_bytes());atomic(generation/'privkey.pem',pathlib.Path(key).read_bytes())
    row=dict(row,cert=str(current/'fullchain.pem'),key=str(current/'privkey.pem'),updated=time.time())
    oldtarget=os.readlink(current) if current.is_symlink() else None
    db=registry();oldrow=db.get(row['id']);was=active();bound=False
    if CONFIG.exists():
        bound=any(i.get('tls',{}).get('certificate_path')==row['cert'] for i in config().get('inbounds',[]))
    try:
        switch_current(current,generation)
        if bound:
            initialize_sync()
            call([binary(),'check','-c',CONFIG])
            if was:service('restart');time.sleep(2);sync_now()
        db[row['id']]=row;save_registry(db)
    except BaseException as failure:
        if oldtarget is not None:switch_current(current,oldtarget)
        elif current.is_symlink():current.unlink()
        if bound and was:
            try:service('restart');time.sleep(1);sync_now(False)
            except Exception:say('⚠ 旧证书已恢复，但服务恢复失败。','warn')
        if oldrow:db[row['id']]=oldrow
        else:db.pop(row['id'],None)
        if isinstance(failure,KeyboardInterrupt):raise failure
        raise Error('证书切换失败，已恢复旧证书。')
    say('✓ 证书已保存：'+row['domain'],'ok')
    if sys.stdin.isatty():
        title('签发完成 · 证书信息')
        try:
            details=call(['openssl','x509','-in',row['cert'],'-noout','-subject','-issuer','-dates','-ext','subjectAltName']).decode(errors='replace')
            print(details,flush=True);say('证书路径：'+row['cert'],'dim');say('私钥路径：'+row['key']+'（不显示私钥内容）','dim')
            title('完整证书 PEM（含证书链）');print(pathlib.Path(row['cert']).read_text(),flush=True)
        except Exception:say('证书已保存，详情展示失败；可通过“查看已有证书”查看。','warn')
    return row

def schedule_renew():
    if alpine():
        path=pathlib.Path('/etc/periodic/daily/argo-cert-renew')
        atomic(path,f'#!/bin/sh\numask 077\nexec /usr/bin/python3 {SELF} renew-due >> {ROOT}/renew.log 2>&1\n',0o700)
        call(['rc-update','add','crond','default']);call(['rc-service','crond','start'])
    else:
        atomic('/etc/systemd/system/argo-cert-renew.service',f'[Service]\nType=oneshot\nExecStart=/usr/bin/python3 {SELF} renew-due\nUMask=0077\nTimeoutStartSec=3600\n')
        atomic('/etc/systemd/system/argo-cert-renew.timer','[Timer]\nOnCalendar=daily\nPersistent=true\nRandomizedDelaySec=1h\n[Install]\nWantedBy=timers.target\n')
        call(['systemctl','daemon-reload']);call(['systemctl','enable','--now','argo-cert-renew.timer'])

@locked
def issue_certificate(host=None,selfsigned=False):
    host=domain(host,True) if host else domain_input('证书域名（DNS 验证可使用 *.example.com）',wildcard=True)
    if selfsigned:
        if host.startswith('*.'):raise Error('自签节点请使用具体域名。')
        row={'id':hashlib.sha256(('self:'+host).encode()).hexdigest()[:20],'domain':host,'kind':'self','client':'openssl','method':'self','email':''}
        with tempfile.TemporaryDirectory(dir=ROOT) as tmp:
            cert=pathlib.Path(tmp)/'cert';key=pathlib.Path(tmp)/'key'
            call(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','3650','-subj','/CN='+host,'-addext','subjectAltName=DNS:'+host,'-keyout',key,'-out',cert],timeout=60)
            return publish_certificate(row,cert,key)
    existing=next((r for r in registry().values() if r['domain']==host and r['kind']=='formal'),None)
    if existing and not confirm('已有该域名证书，重新检查/申请并替换它的管理方式？'):return existing
    method=choose('验证方式：1 Cloudflare DNS API / 2 HTTP（公网 80） / 3 手动 DNS-01（无 API）',('1','2','3'),'1');method={'1':'dns','2':'http','3':'dns-manual'}[method]
    auth=cf_credentials(host) if method=='dns' else None
    email=prompt('ACME 联系邮箱')
    if not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+',email):raise Error('请输入有效邮箱。')
    if method=='dns-manual':
        selected=choose('手动 DNS 申请程序：1 acme.sh / 2 lego',('1','2'),'2');client='acme.sh' if selected=='1' else 'lego'
        say('手动 DNS-01 使用 '+client+'；后续续签也需人工添加 TXT。','warn')
    else:
        client=choose('申请程序：1 acme.sh（主用）/ 2 lego（备用）',('1','2'),'1');client='acme.sh' if client=='1' else 'lego'
    row={'id':existing['id'] if existing else hashlib.sha256(('formal:'+host).encode()).hexdigest()[:20],'domain':host,'kind':'formal','client':client,'method':method,'email':email}
    row['client_home']=str(ROOT/'clients'/row['id']/('attempt-'+str(time.time_ns())+'-'+client))
    if auth is not None:
        authfile=ROOT/'auth'/row['id']/('token-'+str(time.time_ns())+'.json')
        write(authfile,auth);row['auth_file']=str(authfile)
    try:cert,key=client_issue(row)
    except Cancel:raise
    except Exception as e:
        say(str(e),'warn')
        if not confirm('本次申请失败，改用备用程序申请？'):raise Cancel()
        row['client']='lego' if client=='acme.sh' else 'acme.sh'
        row['client_home']=str(ROOT/'clients'/row['id']/('attempt-'+str(time.time_ns())+'-'+row['client']))
        cert,key=client_issue(row)
    result=publish_certificate(row,cert,key)
    if method=='dns-manual':say('✓ 手动 DNS 证书已保存；到期前请进入“续签证书”并按提示更新 TXT。','ok')
    else:schedule_renew();say('✓ 已启用每日续签检查。','ok')
    return result

def list_certificates(select=False,host=None):
    rows=list(registry().items())
    # Include existing node certificate paths for inspection/reuse; never steal renewal ownership.
    known={r['cert'] for _,r in rows}
    if CONFIG.exists():
        for i in config().get('inbounds',[]):
            tls=i.get('tls',{});cert=tls.get('certificate_path');key=tls.get('key_path')
            if not cert or cert in known or not key:continue
            try:
                dns=names(cert);kind=cert_kind(cert)
                row={'id':'external-'+hashlib.sha256(cert.encode()).hexdigest()[:12],'domain':tls.get('server_name',''),'cert':cert,'key':key,'kind':kind,'client':'原安装程序','method':'external'}
                rows.append((row['id'],row));known.add(cert)
            except Exception:continue
    valid=[]
    for rid,row in rows:
        try:
            details=decode_cert(row['cert']);san=names(row['cert']);expires=details['notAfter']
            if host:
                try:check_certificate(row['cert'],row['key'],host,trust=row['kind']=='formal')
                except Exception:continue
            valid.append((rid,row));item(len(valid),', '.join(san)+' · '+('自签' if row['kind']=='self' else '正式')+' · '+expires)
            say('证书：'+row['cert'],'dim');say('私钥路径：'+row['key'],'dim');say('续签程序：'+row['client']+('（手动 DNS，需人工更新 TXT）' if row.get('method')=='dns-manual' else ''),'dim')
        except Exception:say('⚠ 无法读取证书：'+row['cert'],'warn')
    if not valid:say('暂无可用证书。','warn');return None
    if select:
        value=choose('选择证书编号 / 0 返回',tuple(str(i) for i in range(len(valid)+1)))
        return None if value=='0' else valid[int(value)-1][1]
    return valid

def cert_menu():
    while True:
        title('证书申请 / 续签');item(1,'申请正式证书','install');item(2,'查看已有证书');item(3,'续签证书','edit');item(4,'生成自签证书','install');item(0,'返回首页','dim')
        option=choose('请选择',('0','1','2','3','4'))
        if option=='0':return
        try:
            if option=='1':issue_certificate()
            elif option=='4':issue_certificate(selfsigned=True)
            elif option=='2':
                row=list_certificates(True)
                if row and confirm('查看完整证书 PEM（不显示私钥）？'):print(pathlib.Path(row['cert']).read_text())
            else:
                row=list_certificates(True)
                if row:
                    if row['method'] in ('external','self'):raise Error('此证书由原安装程序续签，或为自签证书；可在申请菜单生成并切换新证书。')
                    if confirm('检查并续签 '+row['domain']+'？'):
                        cert,key=client_issue(row,True);publish_certificate(row,cert,key);schedule_renew()
        except Cancel:pass
        except Exception as e:say('错误：'+safe_error(e),'error')

def renew_due():
    failures=0
    for row in registry().values():
        if row['kind']!='formal' or row['method']=='external':continue
        if row['method']=='dns-manual':
            try:check_certificate(row['cert'],row['key'],row['domain'],seconds=30*86400,trust=True)
            except Exception:say('需要人工续签：'+row['domain']+'；请进入 18 → 续签证书更新 TXT。','warn')
            continue
        try:check_certificate(row['cert'],row['key'],row['domain'],seconds=30*86400,trust=True);continue
        except Exception:pass
        try:cert,key=client_issue(row,True);publish_certificate(row,cert,key)
        except Exception as e:failures+=1;say('续签失败：'+row['domain']+' / '+safe_error(e),'warn')
    if failures:raise Error(str(failures)+' 张证书续签失败，请查看日志。')

# ---------- Node editing ----------
def select_certificate(tls):
    title('域名 / 证书');item(1,'保留当前域名与证书','edit');item(2,'从证书列表选择域名');item(3,'手动输入新域名','edit');item(4,'手动指定证书与私钥路径','edit');item(0,'取消','dim')
    choice=choose('请选择',('0','1','2','3','4'),'1')
    if choice=='0':raise Cancel()
    if choice=='1':return None
    if choice=='4':
        host=domain_input('SNI / 域名',tls['server_name']);cert=prompt('证书完整路径',tls.get('certificate_path',''));key=prompt('私钥完整路径',tls.get('key_path',''))
        if not pathlib.Path(cert).is_absolute() or not pathlib.Path(key).is_absolute():raise Error('请输入绝对路径。')
        check_certificate(cert,key,host,trust=cert_kind(cert)=='formal');return {'domain':host,'cert':cert,'key':key,'kind':cert_kind(cert)}
    if choice=='2':
        row=list_certificates(True)
        if not row:raise Cancel()
        host=row['domain']
        if host.startswith('*.'):host=domain_input('通配符证书对应的具体节点域名')
        check_certificate(row['cert'],row['key'],host,trust=row['kind']=='formal');return dict(row,domain=host)
    host=domain_input('新域名',tls['server_name']);matches=matching_rows(host)
    if matches:
        for num,(_,row) in enumerate(matches,1):item(num,row['domain']+' · '+row['kind'])
        idx=choose('选择匹配证书',tuple(str(n) for n in range(1,len(matches)+1)),'1')
        return dict(matches[int(idx)-1][1],domain=host)
    kind=choose('无匹配证书：1 申请正式证书 / 2 生成自签证书 / 0 取消',('0','1','2'),'1')
    if kind=='0':raise Cancel()
    return issue_certificate(host,selfsigned=kind=='2')

def reality_probe(host,sni,port=443):
    # OpenSSL validates the target certificate against local CA roots and requested SNI.
    result=call(['openssl','s_client','-connect',host+':'+str(port),'-servername',sni,'-tls1_3','-verify_hostname',sni,'-verify_return_error'],input=b'',timeout=20)
    if b'TLSv1.3' not in result:raise Error('伪装目标未确认支持 TLS 1.3。')

def select_inbounds(cfg,kind):
    groups={4:[],6:[]};wildcards=[]
    for index,inbound in enumerate(cfg.get('inbounds',[])):
        reality=inbound.get('tls',{}).get('reality',{}).get('enabled',False)
        matches=(kind=='reality' and inbound.get('type')=='vless' and reality) or (kind=='tls' and inbound.get('type')=='vless' and not reality) or (kind=='hy2' and inbound.get('type')=='hysteria2')
        if not matches:continue
        try:family=ipaddress.ip_address(inbound.get('listen','::')).version
        except ValueError:raise Error('无法识别节点监听地址，请检查配置。')
        groups[family].append(index)
        if inbound.get('listen','::')=='::':wildcards.append(index)
    if not any(groups.values()):raise Error('没有该协议的节点。')
    title('选择修改范围');item(1,'IPv4','edit');item(2,'IPv6','edit');item(3,'IPv4 和 IPv6','edit');item(0,'返回上一级','dim')
    selected=choose('请选择修改范围',('0','1','2','3'))
    if selected=='0':raise Cancel()
    # A sole IPv6 wildcard is one configuration, not two independently editable nodes.
    # Do not infer actual IPv4 reachability from the wildcard alone.
    if not groups[4] and len(groups[6])==1 and wildcards==groups[6]:
        index=groups[6][0];inbound=cfg['inbounds'][index]
        say('当前协议只有一组配置，监听 [::]:'+str(inbound['listen_port'])+'；可能接收双栈连接。','warn')
        say('IPv4 是否可连接取决于实际监听和系统设置；UUID、SNI 等是这组配置共用的参数。','dim')
        if selected in ('1','2'):
            say('无法只对 IPv'+('4' if selected=='1' else '6')+' 单独修改这组共用参数。','warn')
            if not confirm('继续修改这组配置（会影响所有使用它的连接）？'):raise Cancel()
        return [index]
    families={'1':[4],'2':[6],'3':[4,6]}[selected];indices=[]
    for family in families:
        candidates=groups[family]
        if not candidates:raise Error('未配置 IPv'+str(family)+' 节点，未修改任何配置。')
        if len(candidates)>1:
            title('选择 IPv'+str(family)+' 节点')
            for number,index in enumerate(candidates,1):
                inbound=cfg['inbounds'][index]
                item(number,inbound.get('tag','节点')+' · 当前 SNI：'+inbound['tls'].get('server_name','未设置')+' · 端口：'+str(inbound['listen_port']))
            value=choose('请输入节点序号 / 0 返回',tuple(str(i) for i in range(len(candidates)+1)))
            if value=='0':raise Cancel()
            indices.append(candidates[int(value)-1])
        else:indices.append(candidates[0])
    return indices

def group_input(label,values,validate=lambda v:v,generate=None,secret=False):
    # Blank means preserve each selected node's value, including differing defaults.
    same=all(v==values[0] for v in values)
    default=str(values[0]) if same and not secret else ''
    shown=('已设置，留空保留' if secret else default or '各自原值')
    while True:
        value=prompt(label+' [当前：'+shown+'；留空保留]',secret=secret)
        if value=='':return None
        try:return generate() if generate and value.lower()=='g' else validate(value)
        except (Error,ValueError):say('↻ 输入格式无效，请重新输入。','retry')

def edit_node(kind):
    cfg=config();old=CONFIG.read_bytes();indices=select_inbounds(cfg,kind);new=copy.deepcopy(cfg);targets=[new['inbounds'][i] for i in indices];display_indices=list(indices)
    title('修改 '+{'reality':'VLESS-Reality','tls':'VLESS-TLS','hy2':'Hysteria2'}[kind])
    for i in indices:
        current=cfg['inbounds'][i];family=ipaddress.ip_address(current.get('listen','::')).version
        label='通配监听（可能双栈）' if current.get('listen','::')=='::' else 'IPv'+str(family)
        say(label+' · '+current.get('tag','节点')+' · 监听：'+('['+current.get('listen','::')+']' if family==6 else current.get('listen','0.0.0.0'))+':'+str(current['listen_port']))
        say('当前 SNI / 域名：'+current['tls'].get('server_name','未设置'),'default')
    say('留空分别保留各自原值；输入新值同时应用到所选节点。','dim')
    users=targets[0].get('users',[])
    if not users or any(not t.get('users') for t in targets):raise Error('节点没有用户。')
    user=0
    if len(users)>1:
        for num,u in enumerate(users,1):item(num,u.get('name','用户 '+str(num)))
        user=int(choose('用户编号',tuple(str(i) for i in range(1,len(users)+1))))-1
    if any(len(t['users'])!=len(users) or t['users'][user].get('name')!=users[user].get('name') for t in targets):
        raise Error('两组节点用户结构不同，请分别修改 IPv4 和 IPv6。')
    selected_users=[t['users'][user] for t in targets]
    if kind=='hy2':
        value=group_input('HY2 密码（G 自动生成）',[u['password'] for u in selected_users],generate=lambda:secrets.token_urlsafe(24),secret=True)
        if value is not None:
            for u in selected_users:u['password']=value
    else:
        value=group_input('UUID（G 自动生成）',[u['uuid'] for u in selected_users],lambda v:str(uuid.UUID(v)),lambda:str(uuid.uuid4()))
        if value is not None:
            for u in selected_users:u['uuid']=value
    def valid_port(v):
        if not v.isdigit() or not 1<=int(v)<=65535:raise Error('端口应为 1–65535。')
        return int(v)
    value=group_input('监听端口',[t['listen_port'] for t in targets],valid_port)
    if value is not None:
        for t in targets:t['listen_port']=value
    if kind=='reality':
        realities=[t['tls']['reality'] for t in targets]
        value=group_input('伪装目标',[r['handshake']['server'] for r in realities],domain)
        if value is not None:
            for r in realities:r['handshake']['server']=value
        value=group_input('客户端 SNI',[t['tls']['server_name'] for t in targets],domain)
        if value is not None:
            for t in targets:t['tls']['server_name']=value
        value=group_input('伪装目标端口',[r['handshake'].get('server_port',443) for r in realities],valid_port)
        if value is not None:
            for r in realities:r['handshake']['server_port']=value
        def valid_sid(v):
            if not re.fullmatch('[a-fA-F0-9]{0,16}',v) or len(v)%2:raise Error('Short ID 格式错误。')
            return v
        value=group_input('Short ID（G 自动生成）',[r['short_id'][0] for r in realities],valid_sid,lambda:secrets.token_hex(4))
        if value is not None:
            for r in realities:r['short_id'][0]=value
        if choose('密钥对：1 保留 / 2 自动生成新密钥对',('1','2'),'1')=='2':
            kp=call([binary(),'generate','reality-keypair']).decode();private=re.search(r'PrivateKey:\s*(\S+)',kp)
            if not private:raise Error('密钥对生成失败。')
            for r in realities:r['private_key']=private.group(1)
            say('新公钥：'+public_key(private.group(1)),'default')
        checked=set()
        for index,target in zip(indices,targets):
            tls=target['tls'];r=tls['reality'];before=cfg['inbounds'][index]['tls'];oldr=before['reality']
            args=(r['handshake']['server'],tls['server_name'],r['handshake'].get('server_port',443))
            oldargs=(oldr['handshake']['server'],before['server_name'],oldr['handshake'].get('server_port',443))
            if args!=oldargs and args not in checked:
                try:reality_probe(*args);checked.add(args)
                except Exception:raise Error('Reality 目标 TLS 1.3 / SNI 校验失败，未保存。')
    else:
        row=select_certificate(targets[0]['tls'])
        if row:
            oldpairs={(t['tls'].get('certificate_path'),t['tls'].get('key_path')) for t in targets}
            shared=[t for j,t in enumerate(new['inbounds']) if j not in indices and
                    (t.get('tls',{}).get('certificate_path'),t.get('tls',{}).get('key_path')) in oldpairs and not t.get('tls',{}).get('reality',{}).get('enabled')]
            allshared=bool(shared) and choose('当前证书被其它节点共用：1 一起更换 / 2 仅所选节点',('1','2'),'2')=='1'
            if allshared:
                display_indices+= [j for j,t in enumerate(new['inbounds']) if j not in display_indices and any(t is other for other in shared)]
            for target in targets+(shared if allshared else []):target['tls'].update(server_name=row['domain'],certificate_path=row['cert'],key_path=row['key'])
        for target in targets:
            tls=target['tls'];check_certificate(tls['certificate_path'],tls['key_path'],tls['server_name'],trust=cert_kind(tls['certificate_path'])=='formal')
    if not confirm('保存所选节点配置、重启 sing-box 并更新节点信息？'):return
    initialize_sync();commit_config(new,old)
    try:
        title('刚修改的节点链接 · 可直接复制')
        print(color('link',generate_links(new,json.loads(META.read_text()),display_indices)),flush=True)
        say('每条链接单独一行；复制到 v2rayN，从剪贴板导入。','dim')
    except Exception:
        say('配置已生效；链接展示失败，可到“查看节点信息”读取已保存链接。','warn')
    if kind=='reality' and alpine() and pathlib.Path('/etc/sing-box/reality_private_key.txt').exists():
        # The legacy informational files hold one pair; update only for a single pair.
        keys={i['tls']['reality']['private_key'] for i in new['inbounds'] if i.get('tls',{}).get('reality',{}).get('enabled')}
        if len(keys)==1:
            key=next(iter(keys));atomic('/etc/sing-box/reality_private_key.txt',key+'\n');atomic('/etc/sing-box/reality_public_key.txt',public_key(key)+'\n')

def node_info():
    if SYNC.exists():sync_now(False)
    path=pathlib.Path('/root/singbox_nodes.txt')
    if not path.exists():path=pathlib.Path('/etc/sing-box/v2rayn_links.txt')
    if not path.exists():raise Error('没有保存的节点信息，请先安装或完成一次配置修改。')
    title('NODE · 节点信息');print(color('link',path.read_text()))

def node_menu():
    while True:
        title('更改节点配置');item(1,'VLESS-Reality','edit');item(2,'VLESS-TLS','edit');item(3,'Hysteria2','edit');item(0,'返回上一级','dim')
        option=choose('请选择',('0','1','2','3'))
        if option=='0':return
        try:edit_node({'1':'reality','2':'tls','3':'hy2'}[option])
        except Cancel:pass
        except Exception as e:say('错误：'+safe_error(e),'error')

def safe_error(error):
    return str(error) if isinstance(error,Error) else ('网络或执行超时，请查看日志。' if isinstance(error,subprocess.TimeoutExpired) else '执行失败，请检查配置、依赖及权限。')
def setup_root():
    os.umask(0o077)
    ROOT.mkdir(parents=True,exist_ok=True);LIB.mkdir(parents=True,exist_ok=True);os.chmod(ROOT,0o700);os.chmod(LIB,0o700)
def main():
    setup_root();action=sys.argv[1] if len(sys.argv)>1 else 'cert-menu'
    if action=='cert-menu':cert_menu()
    elif action=='edit-menu':node_menu()
    elif action=='info':node_info()
    elif action=='cert-list':
        row=list_certificates(True)
        if row and confirm('查看完整证书 PEM（不显示私钥）？'):print(pathlib.Path(row['cert']).read_text())
    elif action=='renew-due':
        with open(ROOT/'renew.lock','a') as f:
            try:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:return
            renew_due()
    elif action=='post-install':
        initialize_sync();service('restart');time.sleep(2);sync_now()
        title('统一命名后的节点链接');print(color('link',LINKFILES[0].read_text()),flush=True)
    else:raise Error('未知管理选项。')
if __name__=='__main__':
    def stop_requested(signum,frame):raise KeyboardInterrupt()
    signal.signal(signal.SIGINT,stop_requested);signal.signal(signal.SIGTERM,stop_requested)
    try:main()
    except KeyboardInterrupt:say('已取消本次操作，申请子进程已清理，管理锁已释放。','warn');sys.exit(130)
    except Cancel:sys.exit(0)
    except Exception as e:say('错误：'+safe_error(e),'error');sys.exit(1)
ARGO_STANDALONE_PY
    chmod 700 "$standalone_helper_tmp"
    mv -f "$standalone_helper_tmp" /usr/local/lib/argo-standalone/manager.py
}
standalone_action() {
    standalone_tools
    python3 /usr/local/lib/argo-standalone/manager.py "$1"
}
singbox_system_menu() {
    standalone_platform=$1
    while :; do
        printf '\n%s  【 sing-box 管理 】%s\n' "$C_CYAN" "$C_RESET"; rule
        menu_item "$C_INSTALL" '1.' '安装 sing-box'
        menu_item "$C_BLUE" '2.' '查看节点信息 / 分享链接'
        menu_item "$C_BLUE" '3.' '查看证书信息'
        menu_item "$C_YELLOW" '4.' '更改节点配置'
        menu_item "$C_DIM" '0.' '返回上一级'
        ask '请选择 [0–4]：'
        case "$REPLY" in
            1)
                run_action singbox_standalone_install "$standalone_platform"
                if [ "$action_result" = 0 ]; then run_action standalone_action post-install; fi;;
            2) run_action standalone_action info;;
            3) run_action standalone_action cert-list;;
            4) run_action standalone_action edit-menu;;
            0) return;;
            *) retry_input '请输入 0–4。'; continue;;
        esac
        ask '按回车返回 sing-box 管理菜单：'
    done
}
singbox_standalone_menu() {
    while :; do
        printf '\n%s  【 singbox一键安装 】%s\n' "$C_CYAN" "$C_RESET"; rule
        printf '  系统  %s%s / %s%s\n\n' "$C_WHITE" "$ID" "$MANAGER" "$C_RESET"
        menu_item "$C_INSTALL" '1.' 'Ubuntu / Debian'
        menu_item "$C_INSTALL" '2.' 'Alpine'
        menu_item "$C_DIM" '0.' '返回首页'
        rule
        ask '请选择 [0–2]：'
        case "$REPLY" in
            1)
                if [ "$MANAGER" != systemd ]; then retry_input '当前是 Alpine，请选择 2。'; continue; fi
                singbox_system_menu debian;;
            2)
                if [ "$MANAGER" != openrc ]; then retry_input '当前是 Ubuntu / Debian，请选择 1。'; continue; fi
                singbox_system_menu alpine;;
            0) return;;
            *) retry_input '请输入 0、1 或 2。';;
        esac
    done
}

main() {
    detect
    terminal_enter
    clear_screen
    while :; do
        header
        printf '\n%s  【 TUNNEL / 隧道管理 】%s\n' "$C_CYAN" "$C_RESET"
        menu_item "$C_INSTALL" '1.' '安装临时隧道（保活 + 开机自启）'
        menu_item "$C_INSTALL" '2.' '安装固定隧道（保活 + 开机自启）'
        menu_item "$C_BLUE" '3.' '查看隧道状态 / 域名'
        menu_item "$C_YELLOW" '4.' '重启隧道'
        menu_item "$C_YELLOW" '5.' '停止隧道'
        menu_item "$C_BLUE" '6.' '查看隧道日志'
        menu_item "$C_RED" '7.' '卸载隧道'
        printf '\n%s  【 NODE / 节点管理 】%s\n' "$C_CYAN" "$C_RESET"
        menu_item "$C_INSTALL" '8.' '安装 / 切换节点核心'
        menu_item "$C_BLUE" '9.' '查询节点信息 / 分享链接'
        menu_item "$C_YELLOW" '10.' '重启节点'
        menu_item "$C_YELLOW" '11.' '停止节点'
        menu_item "$C_BLUE" '12.' '查看节点日志'
        menu_item "$C_INSTALL" '13.' '更新节点核心'
        menu_item "$C_RED" '14.' '卸载节点核心'
        printf '\n%s  【 NETWORK / 网络设置 】%s\n' "$C_CYAN" "$C_RESET"
        menu_item "$C_YELLOW" '15.' '隧道传输（自动 / HTTP2 / QUIC）'
        menu_item "$C_INSTALL" '16.' 'BBR 管理'
        printf '\n%s  【 singbox一键安装 】%s\n' "$C_CYAN" "$C_RESET"
        menu_item "$C_INSTALL" '17.' '安装sing-box'
        menu_item "$C_INSTALL" '18.' '证书申请与续签'
        menu_item "$C_DIM" '0.' '退出'
        rule
        while :; do
            ask '  请选择 [0–18]：'
            case "$REPLY" in 0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18) break;; *) retry_input '请输入 0–18，重新选择即可。';; esac
        done
        case "$REPLY" in
            1) run_action setup quick;; 2) fixed_menu;; 3) run_action status;;
            4) if exists; then run_action control restart; else warn '尚未安装。'; fi;;
            5) run_action stop_if_running;; 6) run_action logs;; 7) run_action uninstall_menu;;
            8) run_action node_menu;; 9) run_action node_info;;
            10) if node_exists; then run_action node_control restart; else warn '尚未安装节点。'; fi;;
            11) if node_exists; then run_action node_stop; else warn '尚未安装节点。'; fi;;
            12) run_action node_logs;; 13) run_action update_node;; 14) run_action remove_node;;
            15) run_action set_transport;; 16) bbr_menu;; 17) singbox_standalone_menu;; 18) run_action standalone_action cert-menu;; 0) exit 0;; *) retry_input '请输入正确选项。';;
        esac
        finish_screen
        clear_screen
    done
}
main "$@"
