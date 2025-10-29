#!/bin/bash
# =========================================================
# Debian 11 → 12 → 13 自動升級腳本
# 特性:
#   - 日誌記錄
#   - 分階段升級 (11->12->13)
#   - 內核檢測與匹配提醒
#   - 自動修復被中斷的 dpkg
#   - 健壯的 APT 源處理
# =========================================================

set -e
LOGFILE="/var/log/debian_upgrade_$(date +%Y%m%d_%H%M%S).log"
exec > >(sudo tee -a "$LOGFILE") 2>&1

pause() {
    echo ""
    read -rp ">>> 按 Enter 鍵繼續..." <> /dev/tty
}

# ---------------- 系統檢測 ----------------
detect_system() {
    echo "--- 檢測系統狀態 ---"

    if [ ! -f /etc/os-release ]; then
        echo "錯誤：無法讀取 /etc/os-release。" >&2
        exit 1
    fi
    . /etc/os-release
    export USERLAND_CODENAME="${VERSION_CODENAME:-unknown}"
    echo "用戶空間 (Userland) 版本: $PRETTY_NAME"

    KERNEL_VERSION=$(uname -r)
    echo "正在運行的內核版本: $KERNEL_VERSION"

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
    echo "內核推斷發行版: $KERNEL_CODENAME"

    if [[ "$USERLAND_CODENAME" == "$KERNEL_CODENAME" ]]; then
        export SYSTEM_STATE="$USERLAND_CODENAME"
        echo "狀態診斷: 內核與用戶空間匹配 ($SYSTEM_STATE)"
    else
        export SYSTEM_STATE="MISMATCHED_KERNEL"
        echo "警告: 內核與用戶空間版本不匹配！($USERLAND_CODENAME / $KERNEL_CODENAME)"
    fi
    echo "---------------------------"
}

# ---------------- 備份與源處理 ----------------
backup_sources() {
    echo "備份 APT 源..."
    sudo cp -a /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%F_%T)
    [ -d /etc/apt/sources.list.d ] && \
        sudo cp -a /etc/apt/sources.list.d /etc/apt/sources.list.d.backup.$(date +%F_%T)
}

fix_sources() {
    FROM=$1
    TO=$2
    echo "更新源: $FROM -> $TO"
    sudo find /etc/apt/ -name "*.list" -type f -exec sed -i \
        -e "s/${FROM}-security/${TO}-security/g" \
        -e "s/${FROM}-updates/${TO}-updates/g" \
        -e "s/${FROM}-backports/${TO}-backports/g" \
        -e "s/${FROM}/${TO}/g" '{}' +
}

# ---------------- 升級流程 ----------------
repair_dpkg() {
    # 檢查 dpkg --audit 的退出碼，如果非0則表示有問題
    if sudo dpkg --audit >/dev/null 2>&1; then
        echo "dpkg 狀態檢查通過，無需修復。"
    else
        echo "警告：檢測到 dpkg 存在問題，正在嘗試自動修復..."
        export DEBIAN_FRONTEND=noninteractive
        sudo dpkg --configure -a
        sudo apt -f install -y
        echo "dpkg 修復完成。"
    fi
}

perform_upgrade() {
    repair_dpkg
    export DEBIAN_FRONTEND=noninteractive
    sudo apt update
    sudo apt -o Dpkg::Options::="--force-confdef" \
             -o Dpkg::Options::="--force-confold" -y full-upgrade
    sudo apt --fix-broken install -y
    sudo apt autoremove --purge -y
    sudo apt clean
}

install_latest_kernel() {
    echo "正在為 $USERLAND_CODENAME 安裝最新推薦內核..."
    sudo apt update
    sudo apt install -y linux-image-amd64 linux-image-cloud-amd64 || \
        echo "一個或多個內核元數據包安裝失敗，這可能是正常的（例如在非雲環境下）。"
}

final_check_and_reboot() {
    echo ""
    echo "==== 驗證最終系統狀態 ===="
    detect_system
    echo ""
    echo "✅ 升級完成，日誌文件位於: $LOGFILE"
    read -rp "是否立即重啟以應用所有變更？(y/n): " REBOOT <> /dev/tty
    if [[ "$REBOOT" =~ ^[Yy]$ ]]; then
        echo "正在重啟..."
        sudo reboot
    else
        echo "操作完成。請記得稍後手動重啟。"
    fi
}

# ---------------- 主流程 ----------------
echo "========================================================="
echo "  Debian 狀態感知升級腳本 (v5.1)"
echo "========================================================="

detect_system
pause

case "$SYSTEM_STATE" in
    bullseye)
        echo "檢測到 Debian 11，開始升級至 Debian 12..."
        backup_sources
        fix_sources bullseye bookworm
        perform_upgrade
        echo "✅ 第一階段完成！"
        echo "🚨 請立即手動重啟 ('sudo reboot')，然後再次運行此腳本繼續升級。"
        exit 0
        ;;
    bookworm)
        echo "檢測到 Debian 12，開始升級至 Debian 13..."
        backup_sources
        fix_sources bookworm trixie
        perform_upgrade
        install_latest_kernel
        echo "✅ 第二階段完成！"
        final_check_and_reboot
        ;;
    trixie)
        echo "檢測到 Debian 13，執行最終檢查。"
        final_check_and_reboot
        ;;
    MISMATCHED_KERNEL)
        echo "檢測到內核與用戶空間版本不匹配，開始修復..."
        install_latest_kernel
        echo "✅ 內核修復嘗試完成。"
        final_check_and_reboot
        ;;
    *)
        echo "錯誤：未知的系統狀態 ($SYSTEM_STATE)，腳本終止。" >&2
        exit 1
        ;;
esac

exit 0
