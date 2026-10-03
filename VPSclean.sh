#!/bin/sh
# VPS cleanup utility. Does not format disks or restore an OS baseline.
set -eu
VERSION=1.1.0
RESET= CYAN= GREEN= YELLOW= RED=
if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then
    RESET=$(printf '\033[0m'); CYAN=$(printf '\033[1;36m')
    GREEN=$(printf '\033[1;32m'); YELLOW=$(printf '\033[1;33m'); RED=$(printf '\033[1;31m')
fi
ask() { printf '  %s%s%s' "$YELLOW" "$1" "$RESET"; IFS= read -r REPLY || exit 0; }
yes() { case "$REPLY" in YES|yes|Y|y) return 0;; *) return 1;; esac; }
die() { printf '  %s错误：%s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }
detect() {
    [ "$(id -u)" = 0 ] || die '请使用 root 运行。'
    . /etc/os-release
    case "$ID" in alpine) MANAGER=openrc;; debian|ubuntu) MANAGER=systemd;; *) die '仅支持 Alpine / Debian / Ubuntu。';; esac
}
# Refuse to traverse mount points, including bind mounts. Symlinks are never followed.
safe_tree() {
    path=$1
    [ ! -L "$path" ] || die "$path 是符号链接，取消本次清理。"
    if awk -v p="$path" '$2 == p || index($2,p "/") == 1 {found=1} END {exit !found}' /proc/mounts; then
        die "$path 内存在挂载点，取消本次清理，请先检查挂载。"
    fi
}
stop_service() {
    svc=$1
    if [ "$MANAGER" = openrc ]; then
        if [ -f "/etc/init.d/$svc" ]; then
            if rc-service "$svc" status >/dev/null 2>&1; then rc-service "$svc" stop; fi
            rc-update del "$svc" default >/dev/null 2>&1 || true
        fi
    else
        if systemctl cat "$svc.service" >/dev/null 2>&1; then
            systemctl stop "$svc.service"
            systemctl disable "$svc.service" >/dev/null 2>&1 || true
        fi
    fi
}
preview_nodes() {
    note '识别范围：本项目 vps-node / vps-tunnel，以及标准名称的 sing-box / singbox / xray / cloudflared。'
    note '非标准脚本名称、未知安装路径不会自动处理。'
    for path in /etc/vps-node /etc/vps-tunnel /etc/sing-box /etc/singbox /etc/xray /etc/cloudflared /usr/local/etc/xray /usr/local/etc/cloudflared /usr/local/lib/vps-node /usr/local/lib/vps-tunnel /usr/local/bin/sing-box /usr/local/bin/singbox /usr/local/bin/xray /usr/local/bin/cloudflared; do
        if [ -e "$path" ] || [ -L "$path" ]; then printf '  删除候选：%s\n' "$path"; fi
    done
    for package in sing-box singbox xray cloudflared; do
        if [ "$MANAGER" = openrc ]; then
            if apk info -e "$package" >/dev/null 2>&1; then printf '  软件包：%s\n' "$package"; fi
        else
            if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then printf '  软件包：%s\n' "$package"; fi
        fi
    done
}
remove_nodes() {
    for path in /etc/vps-node /etc/vps-tunnel /etc/sing-box /etc/singbox /etc/xray /etc/cloudflared /usr/local/etc/xray /usr/local/etc/cloudflared /usr/local/lib/vps-node /usr/local/lib/vps-tunnel; do
        if [ -d "$path" ]; then safe_tree "$path"; fi
    done
    for svc in vps-node vps-tunnel sing-box singbox xray cloudflared; do stop_service "$svc"; done
    for package in sing-box singbox xray cloudflared; do
        if [ "$MANAGER" = openrc ]; then
            # --no-scripts prevents third-party uninstall hooks from removing unrelated paths.
            if apk info -e "$package" >/dev/null 2>&1; then apk del --no-scripts "$package"; fi
        else
            if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
                # Refuse a removal plan that also removes unrelated packages.
                planned=$(apt-get -s remove "$package" | awk '/^Remv / {print $2}')
                for item in $planned; do [ "$item" = "$package" ] || die "卸载计划还会移除 $item，已停止。"; done
                apt-get remove -y "$package"
            fi
        fi
    done
    for svc in vps-node vps-tunnel sing-box singbox xray cloudflared; do
        # Only remove conventional local unit files; leave vendor package directories intact.
        rm -f "/etc/init.d/$svc" "/etc/conf.d/$svc" "/etc/systemd/system/$svc.service"
    done
    if [ "$MANAGER" = systemd ]; then systemctl daemon-reload; fi
    for path in /etc/vps-node /etc/vps-tunnel /etc/sing-box /etc/singbox /etc/xray /etc/cloudflared /usr/local/etc/xray /usr/local/etc/cloudflared /usr/local/lib/vps-node /usr/local/lib/vps-tunnel; do rm -rf "$path"; done
    rm -f /usr/local/bin/sing-box /usr/local/bin/singbox /usr/local/bin/xray /usr/local/bin/cloudflared
    note '已处理标准安装位置；请检查是否仍有非标准服务或手动启动的进程。'
    note 'CF 后台的 Tunnel、DNS 记录未删除。'
}
node_cleanup() {
    preview_nodes
    ask '执行上述节点 / 隧道清理？YES/y 确认：'
    yes || return 0
    remove_nodes
}
project_cleanup() {
    note '仅卸载本项目的 vps-node / vps-tunnel，删除其配置、程序、节点信息和日志。'
    for path in /etc/vps-node /etc/vps-tunnel /usr/local/lib/vps-node /usr/local/lib/vps-tunnel /var/log/vps-tunnel; do
        if [ -e "$path" ]; then printf '  将删除：%s\n' "$path"; safe_tree "$path"; fi
    done
    ask '继续？YES/y 确认：'; yes || return 0
    stop_service vps-node
    stop_service vps-tunnel
    for svc in vps-node vps-tunnel; do
        rm -f "/etc/init.d/$svc" "/etc/conf.d/$svc" "/etc/systemd/system/$svc.service"
    done
    rm -rf /etc/vps-node /etc/vps-tunnel /usr/local/lib/vps-node /usr/local/lib/vps-tunnel /var/log/vps-tunnel
    rm -f /var/log/vps-node.log /var/log/vps-tunnel-service.log
    if [ "$MANAGER" = systemd ]; then systemctl daemon-reload; fi
    note '本项目已卸载；Cloudflare 后台记录需自行删除。'
}
other_nodes() {
    note '以下仅检查，不卸载。非标准服务名和目录可能无法识别。'
    for program in sing-box singbox xray cloudflared; do
        location=$(command -v "$program" 2>/dev/null || true)
        [ -z "$location" ] || printf '  程序：%s → %s\n' "$program" "$location"
        if [ "$MANAGER" = openrc ]; then
            if [ -f "/etc/init.d/$program" ]; then rc-service "$program" status || true; fi
        else systemctl --no-pager status "$program.service" 2>/dev/null || true; fi
    done
    for path in /etc/sing-box /etc/singbox /etc/xray /usr/local/etc/xray; do
        [ ! -e "$path" ] || printf '  配置：%s\n' "$path"
    done
}
package_installed() {
    if [ "$MANAGER" = openrc ]; then apk info -e "$1" >/dev/null 2>&1
    else dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; fi
}
choose_software() {
    note '选择软件包卸载。支持以下常见应用；SSH、网络和系统包不在可选范围。'
    count=0; choices=
    for pkg in sing-box singbox xray cloudflared nginx apache2 mariadb-server mysql-server postgresql redis redis-server docker docker.io containerd; do
        if package_installed "$pkg"; then
            count=$((count + 1)); choices="$choices $pkg"
            printf '  %s. %s\n' "$count" "$pkg"
        fi
    done
    [ "$count" -gt 0 ] || { note '未找到支持卸载的软件包。手动安装的核心请用原脚本卸载。'; return; }
    note '0. 返回'
    while :; do
        ask '请选择软件编号：'
        case "$REPLY" in 0) return;; ''|*[!0-9]*|????*) note '编号错误，请重新输入。'; continue;; esac
        selected=; index=0
        for pkg in $choices; do index=$((index + 1)); if [ "$REPLY" -eq "$index" ]; then selected=$pkg; break; fi; done
        [ -n "$selected" ] && break
        note '编号错误，请重新输入。'
    done
    note "准备卸载软件包：$selected"
    note '使用包管理器移除。数据目录不直接删除；删除数据请单独选择深度清理。'
    if [ "$MANAGER" = openrc ]; then apk del --simulate "$selected"
    else apt-get -s remove "$selected"; fi
    # Reject removal plans affecting other explicit packages on Debian.
    if [ "$MANAGER" = systemd ]; then
        planned=$(apt-get -s remove "$selected" | awk '/^Remv / {print $2}')
        for item in $planned; do [ "$item" = "$selected" ] || die "还会移除 $item，已取消。"; done
    fi
    ask '确认卸载？YES/y 确认：'; yes || return 0
    case "$selected" in
        mariadb-server|mysql-server) stop_service mariadb; stop_service mysql;;
        docker.io) stop_service docker;; redis-server) stop_service redis-server; stop_service redis;;
        *) stop_service "$selected";;
    esac
    if [ "$MANAGER" = openrc ]; then apk del --no-scripts "$selected"
    else apt-get remove -y "$selected"; fi
    note '软件包已移除。配置与用户数据保留。'
    if [ "$MANAGER" = systemd ]; then
        ask '进一步清除该软件包管理的残留配置（purge）？YES/y：'
        if yes; then apt-get purge -y "$selected"; fi
    fi
}
cache_cleanup() {
    note '清理软件包下载缓存；不删除运行中的临时文件。'
    ask '继续？YES/y 确认：'; yes || return 0
    if [ "$MANAGER" = openrc ]; then
        if [ -L /var/cache/apk ]; then die 'APK 缓存目录是链接，请手动检查。'; fi
        if [ -d /var/cache/apk ]; then
            safe_tree /var/cache/apk
            find /var/cache/apk -type f -name '*.apk' -exec rm -f {} \;
        fi
    else apt-get clean; fi
    if command -v systemd-tmpfiles >/dev/null 2>&1; then
        systemd-tmpfiles --clean
        note '临时文件已按系统 tmpfiles 过期策略清理。'
    else note '没有 tmpfiles 清理策略，保留临时文件，避免删除正在使用的数据。'; fi
    note '缓存清理完成。'
}
old_logs() {
    note '只删除 /var/log 下超过 7 天的轮转日志；systemd 日志保留最近 7 天。'
    ask '继续？YES/y 确认：'; yes || return 0
    safe_tree /var/log
    find /var/log -type f \( -name '*.gz' -o -name '*.old' -o -name '*.log.[0-9]' \) -mtime +7 -exec rm -f {} \;
    if [ "$MANAGER" = systemd ]; then journalctl --vacuum-time=7d; fi
}
preview_data() {
    note '深度清理将执行标准节点卸载，并清理：'
    note '  /root 与 /home 下各账号目录：保留 .ssh 和常见 shell 启动文件，其余删除。'
    note '  /var/www、/srv，以及 MySQL / PostgreSQL / Redis / Docker 的标准数据目录。'
    note '保留 /etc 中其他配置、/usr、/boot、账号、SSH、网络、包管理和厂商组件。'
    note '/opt、非标准数据目录和未知软件不自动删除；这不是重装或恢复出厂。'
    for path in /root /home /srv /var/www /var/lib/mysql /var/lib/postgresql /var/lib/redis /var/lib/docker /var/lib/containerd; do
        if [ -d "$path" ]; then du -sh "$path" 2>/dev/null || true; fi
    done
    preview_nodes
}
clean_home() {
    home_path=$1
    safe_tree "$home_path"
    [ ! -L "$home_path/.ssh" ] || die "$home_path/.ssh 是链接，为保护 SSH 已停止。"
    # Preserve login scripts, in addition to SSH keys and authorization files.
    for item in "$home_path"/* "$home_path"/.[!.]* "$home_path"/..?*; do
        [ -e "$item" ] || [ -L "$item" ] || continue
        case "${item##*/}" in .ssh|.profile|.bashrc|.bash_profile|.bash_login|.ashrc|.zshrc|.zprofile) continue;; esac
        rm -rf "$item"
    done
}
deep_cleanup() {
    preview_data
    note '数据无法通过本脚本恢复。请先自行备份。'
    ask '输入 CLEAN-DATA 确认执行预览范围的数据删除：'
    [ "$REPLY" = CLEAN-DATA ] || { note '已取消。'; return 0; }
    if command -v sshd >/dev/null 2>&1; then
        ssh_config=$(sshd -T) || die '无法检查 SSH 配置，取消深度清理。'
        key_paths=$(printf '%s\n' "$ssh_config" | awk '$1=="authorizedkeysfile" {for(i=2;i<=NF;i++) print $i}')
        for key_path in $key_paths; do
            case "$key_path" in .ssh/*|'%h/.ssh/'*|/etc/ssh/*|none) :;; *) die "SSH 使用自定义授权文件 $key_path，请先人工确认保护路径。";; esac
        done
        key_command=$(printf '%s\n' "$ssh_config" | awk '$1=="authorizedkeyscommand" {print $2}')
        case "$key_command" in /root/*|/home/*|/srv/*|/var/www/*) die 'SSH 授权命令位于清理范围，取消深度清理。';; esac
        case "$ssh_config" in *'match '*) die 'SSH 有条件配置，请先人工检查。';; esac
    fi
    # Preflight every data path before stopping services or deleting anything.
    for path in /root /home /srv /var/www /var/lib/mysql /var/lib/postgresql /var/lib/redis /var/lib/docker /var/lib/containerd; do
        if [ -e "$path" ] || [ -L "$path" ]; then safe_tree "$path"; fi
    done
    for home_path in /root /home/*; do
        [ -d "$home_path" ] || continue
        safe_tree "$home_path"
        [ ! -L "$home_path/.ssh" ] || die "$home_path/.ssh 是链接，取消清理。"
    done
    # Keep this running script out of the cleanup scope until the operation completes.
    for svc in nginx apache2 httpd mariadb mysql postgresql redis redis-server docker containerd; do stop_service "$svc"; done
    remove_nodes
    for home_path in /root /home/*; do [ ! -d "$home_path" ] || clean_home "$home_path"; done
    for path in /srv /var/www /var/lib/mysql /var/lib/postgresql /var/lib/redis /var/lib/docker /var/lib/containerd; do
        [ ! -e "$path" ] || rm -rf "$path"
    done
    if [ "$MANAGER" = systemd ]; then apt-get clean; fi
    note '已清理预览范围。未重装系统，未删除 SSH、网络、账号及系统基础组件。'
}
inventory() {
    if [ "$MANAGER" = openrc ]; then apk info; rc-status -a
    else apt-mark showmanual; systemctl --no-pager --type=service --state=running; fi
}
action() {
    set +e
    (set -eu; "$@")
    result=$?
    set -e
    if [ "$result" -ne 0 ]; then note '操作未全部完成，请查看报错；已完成的删除不会自动恢复。'; fi
}
main() {
    detect
    while :; do
        printf '\n%s  VPS · 系统清理 v%s%s\n' "$CYAN" "$VERSION" "$RESET"
        note "系统：$ID / $MANAGER"
        note '──────────────────────────────────────────'
        note '1. 查看已安装软件与运行服务'
        note '2. 清理软件包缓存、临时文件'
        note '3. 清理旧日志'
        note '4. 卸载本项目的隧道和节点'
        note '5. 检查其他脚本安装的 sing-box / Xray'
        note '6. 选择软件并卸载、清理残留'
        printf '  %s7. 深度清理用户数据（预览后确认）%s\n' "$RED" "$RESET"
        note '0. 退出'
        ask '请选择 [0–7]：'
        case "$REPLY" in 1) action inventory;; 2) action cache_cleanup;; 3) action old_logs;; 4) action project_cleanup;; 5) action other_nodes;; 6) action choose_software;; 7) action deep_cleanup;; 0) exit 0;; *) note '请输入正确选项。';; esac
    done
}
main "$@"
