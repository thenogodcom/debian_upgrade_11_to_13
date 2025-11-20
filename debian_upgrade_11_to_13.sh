#!/bin/bash
# =================================================================
# Debian 11 → 12 → 13 全自動無人值守【雲端核心】升級腳本 (生產環境最終版)
# =================================================================
#
# 【變更日誌】:
# - Fix: SSH 斷線防護 (trap HUP)
# - Fix: 軟體源 non-free-firmware 修復
# - Fix: 顯式執行 Cleanup 防止重啟後服務遺失 (審查修復 #3)
# - Add: 磁碟空間檢查 > 5GB (審查修復 #4)
# - Add: 網路連線檢查 (審查修復 #5)
#
# =================================================================

# --- 腳本執行設定 ---
set -e
export DEBIAN_FRONTEND=noninteractive
# 防止 SSH 斷線導致腳本中止
trap '' HUP

# --- 日誌設定 ---
LOGFILE="/var/log/debian_cloud_upgrade_$(date +%Y%m%d_%H%M%S).log"
exec > >(sudo tee -a "$LOGFILE") 2>&1

# --- 全域常數 ---
APT_NONINTERACTIVE_OPTIONS="-y --allow-downgrades --allow-remove-essential --allow-change-held-packages -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef"
ARCH=$(dpkg --print-architecture)
REQUIRED_SPACE_MB=5120 # 5GB

# --- 檢查函數 (Pre-flight Checks) ---

check_root() {
    if [[ $EUID -ne 0 ]]; then
       echo "錯誤：此腳本必須以 root 身份運行 (sudo)。" >&2
       exit 1
    fi
}

check_network() {
    echo "--- [0/7] 檢查網路連線 ---"
    # 嘗試 ping debian.org 或 google dns，超時 5 秒
    if ping -c 1 -W 5 deb.debian.org >/dev/null 2>&1 || ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
        echo "網路連線正常。"
    else
        echo "錯誤：無法連線到網際網路，請檢查網路設定。" >&2
        exit 1
    fi
}

check_disk_space() {
    echo "--- [0/7] 檢查磁碟空間 ---"
    # 獲取根目錄可用空間 (MB)
    local available_space
    available_space=$(df / --output=avail -B M | tail -n 1 | tr -d 'M[:space:]')
    
    echo "根目錄可用空間: ${available_space} MB (需求: ${REQUIRED_SPACE_MB} MB)"
    
    if [ "$available_space" -lt "$REQUIRED_SPACE_MB" ]; then
        echo "錯誤：磁碟空間不足！建議至少保留 5GB 空間進行發行版升級。" >&2
        exit 1
    fi
}

# --- 核心函數 ---

preseed_debconf() {
    echo "--- [1/7] 準備環境依賴 ---"
    sudo apt-get update -q || echo "警告: apt update 返回非零狀態，嘗試繼續..."
    
    if ! sudo apt-get install -y debconf-utils psmisc; then
        echo "錯誤：無法安裝必要工具 (debconf-utils/psmisc)。" >&2
        exit 1
    fi

    echo "預先配置 debconf..."
    sudo debconf-set-selections <<EOF
libc6 libraries/restart-without-asking boolean true
EOF
}

configure_unattended_tools() {
    echo "暫停自動更新服務..."
    sudo systemctl stop unattended-upgrades.service || true
    sudo systemctl disable unattended-upgrades.service || true
    
    if [ -f /etc/needrestart/needrestart.conf ]; then
        sudo sed -i "s/^#*\$nrconf{restart}.*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf
    fi
    
    if ! dpkg -s apt-listchanges >/dev/null 2>&1; then
        sudo apt-get install -y apt-listchanges
    fi
    sudo sed -i "s/frontend=.*/frontend=none/" /etc/apt/apt.conf.d/20listchanges
}

# 恢復服務函數 (需在退出或重啟前顯式調用)
restore_services() {
    echo "正在恢復 unattended-upgrades 服務狀態..."
    sudo systemctl enable unattended-upgrades.service || true
    sudo systemctl start unattended-upgrades.service || true
    echo "服務恢復完成。"
}

# Trap 僅作為異常退出的保險，正常重啟流程應顯式調用 restore_services
trap restore_services EXIT

pause() {
    echo ""
    if [ -t 0 ]; then
        read -rp ">>> 將在 5 秒後繼續，按 Ctrl+C 中止..." -t 5 <> /dev/tty || true
    else
        echo ">>> 無人值守模式：將在 5 秒後自動繼續..."
        sleep 5
    fi
}

detect_system() {
    echo "--- [2/7] 檢測系統狀態 ---"
    if [ ! -f /etc/os-release ]; then
        echo "錯誤：無法讀取 /etc/os-release。" >&2
        exit 1
    fi
    . /etc/os-release
    export USERLAND_CODENAME="${VERSION_CODENAME:-unknown}"
    export SYSTEM_STATE="$USERLAND_CODENAME"
    
    echo "當前發行版: $USERLAND_CODENAME"
    echo "當前核心: $(uname -r)"
}

backup_sources() {
    echo "備份 APT 來源..."
    local ts=$(date +%F_%T)
    sudo cp -a /etc/apt/sources.list "/etc/apt/sources.list.backup.${ts}"
    [ -d /etc/apt/sources.list.d ] && \
        sudo cp -a /etc/apt/sources.list.d "/etc/apt/sources.list.d.backup.${ts}"
}

fix_sources() {
    local FROM=$1
    local TO=$2
    echo "--- [3/7] 更新軟體源: $FROM -> $TO ---"
    
    # 修復舊式安全源格式
    if grep -q "${FROM}/updates" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
        sudo find /etc/apt/ -name "*.list" -type f -exec sed -i "s|${FROM}/updates|${FROM}-security|g" '{}' +
    fi

    # 執行版本替換
    sudo find /etc/apt/ -name "*.list" -type f -exec sed -i \
        "s/${FROM}-security/${TO}-security/g; s/${FROM}-updates/${TO}-updates/g; s/${FROM}-backports/${TO}-backports/g; s/${FROM}/${TO}/g" '{}' +

    # 適配 non-free-firmware
    if [[ "$TO" == "bookworm" ]] || [[ "$TO" == "trixie" ]]; then
        # 確保 non-free 和 main 後面都跟著 non-free-firmware
        sudo find /etc/apt/ -name "*.list" -type f -exec sed -i \
            '/non-free/ { /non-free-firmware/! s/non-free/non-free non-free-firmware/g }' '{}' +
        sudo find /etc/apt/ -name "*.list" -type f -exec sed -i \
            '/main/ { /non-free/! { /non-free-firmware/! s/main/main non-free-firmware/g } }' '{}' +
    fi
}

repair_dpkg() {
    if sudo lsof /var/lib/dpkg/lock >/dev/null 2>&1; then
        echo "移除 dpkg 鎖..."
        sudo fuser -k /var/lib/dpkg/lock || true
        sudo rm -f /var/lib/dpkg/lock*
    fi
    if ! sudo dpkg --audit >/dev/null 2>&1; then
        echo "修復中斷的安裝..."
        sudo dpkg --configure -a
        sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} -f install
    fi
}

perform_upgrade() {
    repair_dpkg
    echo "--- [4/7] 執行系統升級 ---"
    sudo -E apt update
    sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} full-upgrade
    sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} --fix-broken install
    sudo -E apt autoremove --purge -y
    sudo -E apt clean
}

upgrade_to_cloud_kernel() {
    echo "--- [5/7] 標準化至【雲端服務核心】 ---"
    sudo -E apt update
    sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} --no-install-recommends install "linux-image-cloud-${ARCH}"
    
    if dpkg -l | grep -q "linux-image-cloud-${ARCH}"; then
        echo "雲端核心安裝成功，移除通用核心..."
        if dpkg -s "linux-image-${ARCH}" >/dev/null 2>&1; then
            sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} remove "linux-image-${ARCH}"
        fi
    fi
}

reboot_sequence() {
    local msg=$1
    echo ""
    echo "--- [6/7] $msg ---"
    echo "正在恢復服務設定..."
    restore_services # 【關鍵修復】：在重啟前顯式恢復服務
    
    echo "系統將在 10 秒後重啟..."
    sleep 10
    
    # 解除 trap，避免退出時重複執行 restore_services (雖然重複執行也無害，但這樣更乾淨)
    trap - EXIT 
    
    echo "REBOOTING NOW..."
    sudo reboot -f
    sleep infinity
}

# --- 主流程 ---
check_root
check_network
check_disk_space

echo "========================================================="
echo "  Debian 生產環境雲端升級腳本 (Final)"
echo "========================================================="

preseed_debconf
configure_unattended_tools
detect_system
pause

run_upgrade_flow() {
    backup_sources
    fix_sources "$1" "$2"
    perform_upgrade
    upgrade_to_cloud_kernel 
}

case "$SYSTEM_STATE" in
    bullseye)
        echo "狀態: Debian 11 -> 12"
        run_upgrade_flow bullseye bookworm
        reboot_sequence "第一階段完成，需要重啟加載新核心"
        ;;
    bookworm)
        echo "狀態: Debian 12 -> 13"
        run_upgrade_flow bookworm trixie
        echo "--- [7/7] 升級全部完成 ---"
        reboot_sequence "所有階段完成，執行最終重啟"
        ;;
    trixie)
        echo "狀態: 系統已是 Trixie"
        perform_upgrade
        upgrade_to_cloud_kernel
        reboot_sequence "維護完成，執行重啟"
        ;;
    *)
        echo "未知狀態，執行通用更新"
        perform_upgrade
        upgrade_to_cloud_kernel
        reboot_sequence "通用更新完成，執行重啟"
        ;;
esac

exit 0
