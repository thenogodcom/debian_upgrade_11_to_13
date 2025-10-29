#!/bin/bash
# =========================================================
# Debian 11 → 12 → 13 自動升級腳本
# 適用於：Debian 11 (Bullseye) 到 Debian 13 (Trixie)
# 作者：ChatGPT (GPT-5)
# =========================================================

set -e

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

update_system() {
    echo ""
    echo "==== 更新並清理系統 ===="
    sudo apt update
    sudo apt full-upgrade -y
    sudo apt --fix-broken install -y
    sudo apt autoremove --purge -y
    sudo apt clean
}

upgrade_to_bookworm() {
    echo ""
    echo "==== 開始升級 Debian 11 → 12 (Bookworm) ===="
    backup_sources
    sudo sed -i 's/bullseye/bookworm/g' /etc/apt/sources.list
    sudo apt update
    sudo apt upgrade -y
    sudo apt full-upgrade -y
    sudo apt --fix-broken install -y
    sudo apt autoremove --purge -y
    echo ""
    echo "升級到 Debian 12 完成，將重啟系統..."
    # sudo reboot
}

upgrade_to_trixie() {
    echo ""
    echo "==== 開始升級 Debian 12 → 13 (Trixie) ===="
    backup_sources
    sudo sed -i 's/bookworm/trixie/g' /etc/apt/sources.list
    sudo apt update
    sudo apt upgrade -y
    sudo apt full-upgrade -y
    sudo apt --fix-broken install -y
    sudo apt autoremove --purge -y
    echo ""
    echo "升級到 Debian 13 完成，將重啟系統..."
    sudo reboot
}

final_check() {
    echo ""
    echo "==== 驗證系統版本 ===="
    lsb_release -a || cat /etc/debian_version
    uname -a
    echo ""
    echo "==== 系統清理 ===="
    sudo apt clean
    sudo apt autoremove -y
    echo ""
    echo "✅ 升級已完成！"
}

# --- 主流程 ---
echo "========================================================="
echo "  Debian 自動升級腳本：11 → 12 → 13"
echo "========================================================="
check_version
echo "請確保："
echo "  1. 已備份 /etc /home /var/www /usr/local"
echo "  2. 已停用所有第三方源 (Docker, MariaDB, NodeSource 等)"
echo "  3. 有足夠磁碟空間 (>2GB)"
echo ""
pause

echo "第一階段：升級至 Debian 12 (Bookworm)"
upgrade_to_bookworm

# --- 第二次啟動後繼續 ---
if grep -q "bookworm" /etc/apt/sources.list; then
    echo "檢測到系統為 Debian 12，準備升級至 Debian 13..."
    pause
    upgrade_to_trixie
fi

# --- 第三次啟動後檢查 ---
if grep -q "trixie" /etc/apt/sources.list; then
    final_check
fi
