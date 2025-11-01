#!/bin/bash
# =================================================================
# Debian 11 → 12 → 13 全自動無人值守【雲端核心】升級腳本 (最終修復版)
# =================================================================
#
# 【警告】: 此腳本已修改為專門安裝和使用為雲端伺服器優化的核心
# (linux-image-cloud-*). 請勿在需要特定硬體驅動的桌面或
# 實體伺服器上使用，否則可能導致無法開機或設備不工作。
#

# --- 腳本執行設定 ---
set -e
export DEBIAN_FRONTEND=noninteractive

# --- 日誌設定 ---
LOGFILE="/var/log/debian_cloud_upgrade_$(date +%Y%m%d_%H%M%S).log"
exec > >(sudo tee -a "$LOGFILE") 2>&1

# --- 全域常數 ---
APT_NONINTERACTIVE_OPTIONS="-y --allow-downgrades --allow-remove-essential --allow-change-held-packages -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef"
ARCH=$(dpkg --print-architecture)

# --- 函數定義 ---

# 【根本性修復】: 新增函數，使用 debconf-set-selections 預先回答關鍵問題
# 這是解決 libc6 彈出視窗的最可靠方法。
preseed_debconf() {
    echo "--- 預先配置 debconf 以避免互動 ---"
    # 使用 here-document 傳入配置，可讀性更好
    # libraries/restart-without-asking=true 會自動回答 "Restart services during package upgrades without asking?" 為 <Yes>
    sudo debconf-set-selections <<EOF
libc6 libraries/restart-without-asking boolean true
EOF
    echo "debconf 已預先配置。"
}


configure_unattended_tools() {
    echo "配置 unattended-upgrades 和 needrestart 為非互動模式..."
    sudo systemctl stop unattended-upgrades.service || true
    sudo systemctl disable unattended-upgrades.service || true
    if [ -f /etc/needrestart/needrestart.conf ]; then
        sudo sed -i "s/^#*\$nrconf{restart}.*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf
        echo "needrestart 已配置為自動重啟服務。"
    fi
    if ! dpkg -s apt-listchanges >/dev/null 2>&1; then
        sudo apt-get install -y apt-listchanges
    fi
    sudo sed -i "s/frontend=.*/frontend=none/" /etc/apt/apt.conf.d/20listchanges
}

cleanup() {
    echo "腳本執行結束，正在恢復 unattended-upgrades 服務..."
    sudo systemctl enable unattended-upgrades.service || true
    sudo systemctl start unattended-upgrades.service || true
    echo "服務已恢復。"
}
trap cleanup EXIT

pause() {
    echo ""
    read -rp ">>> 這是一個全自動【雲端核心】升級腳本，將在5秒後繼續，按 Ctrl+C 中止..." -t 5 <> /dev/tty || true
}

detect_system() {
    # ... (此函數無變更) ...
    echo "--- 檢測系統狀態 ---"
    if [ ! -f /etc/os-release ]; then
        echo "錯誤：無法讀取 /etc/os-release，無法確定系統版本。" >&2
        exit 1
    fi
    . /etc/os-release
    export USERLAND_CODENAME="${VERSION_CODENAME:-unknown}"
    echo "使用者空間 (Userland) 版本: $PRETTY_NAME"
    KERNEL_VERSION=$(uname -r)
    echo "正在運行的核心版本: $KERNEL_VERSION"
    case "${KERNEL_VERSION%%.*}" in
        5) KERNEL_CODENAME="bullseye" ;;
        6)
            if dpkg --compare-versions "$KERNEL_VERSION" "lt" "6.2"; then
                KERNEL_CODENAME="bookworm"
            else
                KERNEL_CODENAME="trixie"
            fi
            ;;
        *) KERNEL_CODENAME="unknown" ;;
    esac
    echo "核心推斷發行版: $KERNEL_CODENAME"
    if [[ "$USERLAND_CODENAME" == "$KERNEL_CODENAME" ]]; then
        export SYSTEM_STATE="$USERLAND_CODENAME"
        echo "狀態診斷: 核心與使用者空間匹配 ($SYSTEM_STATE)"
    else
        export SYSTEM_STATE="MISMATCHED_KERNEL"
        echo "警告: 核心與使用者空間版本不匹配！(使用者空間: $USERLAND_CODENAME / 核心: $KERNEL_CODENAME)"
    fi
    echo "---------------------------"
}

backup_sources() {
    # ... (此函數無變更) ...
    echo "備份 APT 來源..."
    local backup_timestamp
    backup_timestamp=$(date +%F_%T)
    sudo cp -a /etc/apt/sources.list "/etc/apt/sources.list.backup.${backup_timestamp}"
    [ -d /etc/apt/sources.list.d ] && \
        sudo cp -a /etc/apt/sources.list.d "/etc/apt/sources.list.d.backup.${backup_timestamp}"
}

fix_sources() {
    # ... (此函數無變更) ...
    local FROM=$1
    local TO=$2
    echo "更新來源: $FROM -> $TO"
    sudo find /etc/apt/ -name "*.list" -type f -exec sed -i \
        "s/${FROM}-security/${TO}-security/g; s/${FROM}-updates/${TO}-updates/g; s/${FROM}-backports/${TO}-backports/g; s/${FROM}/${TO}/g" '{}' +
}

repair_dpkg() {
    # 【防禦性加固】: 使用 -E 參數確保 sudo 繼承 DEBIAN_FRONTEND 環境變數
    if sudo lsof /var/lib/dpkg/lock >/dev/null 2>&1 || sudo lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        echo "警告：檢測到 dpkg 鎖文件，正在強制移除..."
        sudo fuser -k /var/lib/dpkg/lock || true
        sudo fuser -k /var/lib/dpkg/lock-frontend || true
        sudo rm -f /var/lib/dpkg/lock*
    fi
    if ! sudo dpkg --audit >/dev/null 2>&1; then
        echo "警告：檢測到 dpkg 存在未完成的設定，正在嘗試自動修復..."
        sudo dpkg --configure -a
        sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} -f install
        echo "dpkg 修復完成。"
    else
        echo "dpkg 狀態檢查通過。"
    fi
}

perform_upgrade() {
    repair_dpkg
    echo "開始更新套件列表..."
    sudo -E apt update
    echo "開始全系統升級..."
    # 【防禦性加固】: 使用 -E 參數確保 sudo 繼承 DEBIAN_FRONTEND 環境變數
    sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} full-upgrade
    echo "執行最終清理..."
    sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} --fix-broken install
    sudo -E apt autoremove --purge
    sudo -E apt clean
}

upgrade_to_cloud_kernel() {
    echo "--- 標準化至最新的【雲端服務核心】(架構: ${ARCH}) ---"
    sudo -E apt update
    echo "步驟 1: 安裝最新的雲端核心元數據包..."
    sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} --no-install-recommends install "linux-image-cloud-${ARCH}"
    echo "雲端核心 'linux-image-cloud-${ARCH}' 已成功安裝/更新。"
    echo "步驟 2: 移除通用核心元數據包以避免未來衝突..."
    if dpkg -s "linux-image-${ARCH}" >/dev/null 2>&1; then
        sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} remove "linux-image-${ARCH}"
        echo "通用核心元數據包 'linux-image-${ARCH}' 已被移除。"
    else
        echo "通用核心元數據包 'linux-image-${ARCH}' 未安裝，無需移除。"
    fi
    echo "✅ 系統已配置為專用雲端服務核心。"
    echo "---------------------------------------------------------"
}

final_check_and_auto_reboot() {
    echo ""
    echo "==== 驗證最終系統狀態 ===="
    detect_system
    echo ""
    echo "✅ 升級流程已全部完成！日誌文件位於: $LOGFILE"
    echo "系統將在 10 秒後自動重啟以應用所有變更（包括新的雲端核心）..."
    sleep 10
    echo "正在重啟..."
    sudo reboot -f
}

# --- 主流程 ---
echo "========================================================="
echo "  Debian 全自動無人值守【雲端核心】升級腳本 (最終修復版)"
echo "========================================================="
echo "日誌將被記錄到: $LOGFILE"

# 在所有 apt 操作前，執行 debconf 預配置
preseed_debconf
configure_unattended_tools
detect_system
pause

# 主升級流程
run_upgrade_flow() {
    local from_codename=$1
    local to_codename=$2
    echo "開始升級: $from_codename -> $to_codename..."
    backup_sources
    fix_sources "$from_codename" "$to_codename"
    perform_upgrade
    # 邏輯調整: 升級完系統後，立刻處理核心
    upgrade_to_cloud_kernel 
}

case "$SYSTEM_STATE" in
    bullseye)
        run_upgrade_flow bullseye bookworm
        echo ""
        echo "✅ 第一階段完成！"
        echo "🚨 正在自動重啟以應用 Debian 12 的雲端核心。請在重啟後，再次運行此腳本以繼續升級到 Debian 13。"
        sleep 5
        sudo reboot -f
        ;;
    bookworm)
        run_upgrade_flow bookworm trixie
        echo "✅ 第二階段完成！"
        final_check_and_auto_reboot
        ;;
    trixie)
        echo "檢測到 Debian 13 (trixie)，系統已是最新。執行最終檢查和核心標準化。"
        perform_upgrade
        upgrade_to_cloud_kernel
        final_check_and_auto_reboot
        ;;
    MISMATCHED_KERNEL)
        echo "檢測到核心與使用者空間版本不匹配，將嘗試修復..."
        upgrade_to_cloud_kernel
        echo "✅ 核心修復嘗試完成。"
        final_check_and_auto_reboot
        ;;
    *)
        echo "錯誤：未知的系統狀態 ($SYSTEM_STATE)，腳本終止。" >&2
        exit 1
        ;;
esac

exit 0
