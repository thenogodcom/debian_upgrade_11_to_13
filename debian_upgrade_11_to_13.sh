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
    # 使用 find 命令處理 /etc/apt/sources.list 和 /etc/apt/sources.list.d/ 中的所有 .list 文件
    sudo find /etc/apt/ -name "*.list" -type f -exec sed -i \
        -e "s/${FROM_CODENAME}-security/${TO_CODENAME}-security/g" \
        -e "s/${FROM_CODENAME}-updates/${TO_CODENAME}-updates/g" \
        -e "s/${FROM_CODENAME}-backports/${TO_CODENAME}-backports/g" \
        -e "s/${FROM_CODENAME}/${TO_CODENAME}/g" '{}' +
}

# 統一的升級步驟函數
perform_upgrade_steps() {
    echo "開始更新軟件包列表並執行升級..."
    export DEBIAN_FRONTEND=noninteractive
    sudo apt update
    sudo apt -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y full-upgrade
    sudo apt --fix-broken install -y
    sudo apt autoremove --purge -y
    sudo apt clean
}

# 最終檢查和重啟提示
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

if ! source /etc/os-release; then
    echo "錯誤：無法讀取 /etc/os-release 文件。" >&2
    exit 1
fi

check_version
pause

case "$VERSION_CODENAME" in
  bullseye)
    echo "檢測到 Debian 11。準備升級至 Debian 12..."
    backup_sources
    fix_sources bullseye bookworm
    perform_upgrade_steps
    echo ""
    echo "✅ 第一階段 (-> Debian 12) 完成！"
    echo "🚨 請立即手動重啟 ('sudo reboot')，然後再次運行此腳本繼續升級。"
    exit 0 # <--- 關鍵：在此處退出，強制分階段執行
    ;;
  bookworm)
    echo "檢測到 Debian 12。準備升級至 Debian 13..."
    backup_sources
    fix_sources bookworm trixie
    perform_upgrade_steps
    echo ""
    echo "✅ 第二階段 (-> Debian 13) 完成！"
    final_check_and_reboot # <--- 升級到最終版本後，才進行檢查和重啟
    ;;
  trixie)
    echo "檢測到系統已是 Debian 13 (Trixie)。"
    final_check_and_reboot
    ;;
  *)
    echo "錯誤：不支持的版本 ($VERSION_CODENAME)。腳本終止。" >&2
    exit 1
    ;;
esac

exit 0
