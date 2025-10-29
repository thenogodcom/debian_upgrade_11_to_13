#!/bin/bash
# =========================================================
# Debian 11 → 12 → 13 自動升級腳本
# 特性: 日誌記錄, 健壯的源處理, 狀態感知, 分階段執行
# =========================================================

set -e
LOGFILE="/var/log/debian_upgrade_$(date +%Y%m%d_%H%M%S).log"

# 將所有輸出同時打印到屏幕和日誌文件
exec > >(tee -a "$LOGFILE") 2>&1

# --- 函數定義 ---
pause() {
    echo ""
    read -rp ">>> 按 Enter 鍵繼續..."
}

detect_system() {
    echo "檢測系統版本..."
    UNAME_K="$(uname -r)"
    echo "Kernel: $UNAME_K"

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME="${NAME:-Unknown}"
        OS_VERSION_ID="${VERSION_ID:-Unknown}"
        OS_CODENAME="${VERSION_CODENAME:-Unknown}"
        echo "/etc/os-release: $OS_NAME $OS_VERSION_ID ($OS_CODENAME)"
    else
        echo "錯誤：無法讀取 /etc/os-release" >&2
        exit 1
    fi

    if [ -f /etc/debian_version ]; then
        DEBIAN_VER="$(cat /etc/debian_version)"
        echo "/etc/debian_version: $DEBIAN_VER"
    fi

    if command -v lsb_release >/dev/null 2>&1; then
        echo "lsb_release: $(lsb_release -ds)"
    fi

    # 優先使用 /etc/os-release 判斷 codename
    if [ -n "$OS_CODENAME" ] && [ "$OS_CODENAME" != "Unknown" ]; then
        DETECTED_CODENAME="$OS_CODENAME"
    else
        case "${DEBIAN_VER%%.*}" in
            11) DETECTED_CODENAME="bullseye" ;;
            12) DETECTED_CODENAME="bookworm" ;;
            13) DETECTED_CODENAME="trixie" ;;
            *) DETECTED_CODENAME="unknown" ;;
        esac
    fi

    echo "推斷發行代號: $DETECTED_CODENAME"
    export CURRENT_CODENAME="$DETECTED_CODENAME"
    export CURRENT_VERSION_ID="${OS_VERSION_ID:-$DEBIAN_VER}"
}

check_version() {
    echo "目前系統版本："
    lsb_release -a || cat /etc/debian_version
    echo ""
}

backup_sources() {
    echo "備份 sources.list ..."
    sudo cp /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%Y%m%d_%H%M%S)
}

# 改良的源文件處理函數
fix_sources() {
    FROM_CODENAME=$1
    TO_CODENAME=$2
    echo "正在將源從 '$FROM_CODENAME' 更新到 '$TO_CODENAME'..."
    sudo find /etc/apt/ -name "*.list" -type f -exec sed -i \
        -e "s/${FROM_CODENAME}-security/${TO_CODENAME}-security/g" \
        -e "s/${FROM_CODENAME}-updates/${TO_CODENAME}-updates/g" \
        -e "s/${FROM_CODENAME}-backports/${TO_CODENAME}-backports/g" \
        -e "s/${FROM_CODENAME}/${TO_CODENAME}/g" '{}' +
}

perform_upgrade_steps() {
    echo "開始更新軟件包列表並執行升級..."
    export DEBIAN_FRONTEND=noninteractive
    sudo apt update
    sudo apt -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y full-upgrade
    sudo apt --fix-broken install -y
    sudo apt autoremove --purge -y
    sudo apt clean
}

final_check_and_reboot() {
    echo ""
    echo "==== 驗證最終系統版本 ===="
    lsb_release -a || cat /etc/debian_version
    uname -a
    echo ""
    echo "✅ 升級流程已全部完成！日誌已保存至：$LOGFILE"
    echo ""
    read -rp "是否立即重啟以應用所有變更？(y/n): " REBOOT
    if [[ "$REBOOT" =~ ^[Yy]$ ]]; then
        echo "正在重啟..."
        sudo reboot
    else
        echo "請記得稍後手動重啟。"
    fi
}

# --- 主流程 ---
echo "========================================================="
echo "  Debian 狀態感知升級腳本"
echo "========================================================="

detect_system
check_version
pause

case "$CURRENT_CODENAME" in
    bullseye)
        echo "檢測到 Debian 11。準備升級至 Debian 12..."
        backup_sources
        fix_sources bullseye bookworm
        perform_upgrade_steps
        echo ""
        echo "✅ 第一階段 (-> Debian 12) 完成！"
        echo "🚨 請立即手動重啟 ('sudo reboot')，然後再次運行此腳本繼續升級。"
        exit 0
        ;;
    bookworm)
        echo "檢測到 Debian 12。準備升級至 Debian 13..."
        backup_sources
        fix_sources bookworm trixie
        perform_upgrade_steps
        echo ""
        echo "✅ 第二階段 (-> Debian 13) 完成！"
        final_check_and_reboot
        ;;
    trixie)
        echo "檢測到系統已是 Debian 13 (Trixie)。"
        final_check_and_reboot
        ;;
    *)
        echo "錯誤：不支持的版本 ($CURRENT_CODENAME)。腳本終止。" >&2
        exit 1
        ;;
esac

exit 0
