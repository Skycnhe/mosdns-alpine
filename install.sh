#!/bin/sh

# ==========================================
# Alpine Linux MosDNS 一键安装脚本
# 模式: GitHub 直连 (无加速)
# 特性: 强制清理旧文件，全新安装
# ==========================================

# 1. 遇到错误立即停止
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 变量定义
MOSDNS_VERSION="v5.3.3"
WORK_DIR="/etc/mosdns"
BIN_DIR="/usr/bin"

# === 已移除加速镜像变量 ===

log() { echo -e "${GREEN}[Info]${PLAIN} $1"; }
err() { echo -e "${RED}[Error]${PLAIN} $1"; exit 1; }

# === Root 检查 ===
[ "$(id -u)" != "0" ] && err "需要 Root 权限运行。"

# === 架构检测 ===
case $(uname -m) in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *)       err "不支持的架构: $(uname -m)" ;;
esac
log "检测架构: $ARCH"

# === 环境准备 ===
log "配置基础环境..."
# APK 软件源依然保留阿里云，为了保证基础依赖(curl/wget)能快速安装
# 如果你在海外，可以注释掉下面这一行
sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories
apk update || true
apk add curl wget tar unzip ca-certificates tzdata

cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime 2>/dev/null || true
echo "Asia/Shanghai" > /etc/timezone

# === 下载 MosDNS (GitHub 直连) ===
log "准备下载 MosDNS ($MOSDNS_VERSION) [GitHub 直连]..."
mkdir -p ${WORK_DIR}
cd /tmp

# [清理] 强制删除旧的安装包和解压残留
if ls mosdns* 1> /dev/null 2>&1; then
    rm -rf mosdns*
fi

# [清理] 强制删除旧的二进制程序
if [ -f "${BIN_DIR}/mosdns" ]; then
    rm -f "${BIN_DIR}/mosdns"
fi

# [下载] 无加速
URL="https://github.com/IrineSistiana/mosdns/releases/download/${MOSDNS_VERSION}/mosdns-linux-${ARCH}.zip"
log "URL: $URL"
wget -O mosdns.zip "$URL"

# === 安装二进制 ===
unzip -o mosdns.zip > /dev/null
if [ -f "mosdns" ]; then
    mv mosdns ${BIN_DIR}/mosdns
elif [ -d "mosdns-linux-${ARCH}" ]; then
    mv mosdns-linux-${ARCH}/mosdns ${BIN_DIR}/mosdns
else
    find . -type f -name "mosdns" -exec mv {} ${BIN_DIR}/mosdns \;
fi

[ ! -f "${BIN_DIR}/mosdns" ] && err "未找到二进制文件，安装失败！"
chmod +x ${BIN_DIR}/mosdns
log "MosDNS 主程序安装完成"

# === 下载规则文件 (GitHub 直连) ===
log "准备下载 GeoIP/GeoSite [GitHub 直连]..."
cd ${WORK_DIR}

# [清理] 强制删除旧的规则文件
if [ -f "geoip.dat" ]; then
    rm -f geoip.dat
fi
if [ -f "geosite.dat" ]; then
    rm -f geosite.dat
fi

# [下载] 无加速
log "正在下载 geoip.dat..."
wget -O geoip.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"

log "正在下载 geosite.dat..."
wget -O geosite.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

# === 生成配置 ===
log "重写 config.yaml..."
cat > ${WORK_DIR}/config.yaml <<EOF
log:
  level: info
  file: "/var/log/mosdns.log"

plugins:
  - tag: cache
    type: cache
    args:
      size: 10240
      lazy_cache_ttl: 86400

  - tag: forward_local
    type: forward
    args:
      upstreams:
        - addr: "223.5.5.5"
        - addr: "119.29.29.29"

  - tag: forward_remote
    type: forward
    args:
      upstreams:
        - addr: "8.8.8.8"
        - addr: "1.1.1.1"

  - tag: main_sequence
    type: sequence
    args:
      - exec: \$cache
      - matches:
          - qname \$geosite.dat:cn
        exec: \$forward_local
      - matches:
          - has_resp
        exec: accept
      - exec: \$forward_remote

servers:
  - exec: main_sequence
    listeners:
      - protocol: udp
        addr: ":5335"
      - protocol: tcp
        addr: ":5335"
EOF

# === 配置服务 ===
log "刷新 OpenRC 服务配置..."
cat > /etc/init.d/mosdns <<EOF
#!/sbin/openrc-run
name="mosdns"
command="${BIN_DIR}/mosdns"
command_args="start -c ${WORK_DIR}/config.yaml -d ${WORK_DIR}"
command_background=true
pidfile="/run/mosdns.pid"
depend() {
    need net
    after firewall
}
EOF
chmod +x /etc/init.d/mosdns
rc-update add mosdns default > /dev/null

# === 启动验证 ===
log "重启 MosDNS 服务..."
service mosdns stop 2>/dev/null || true
service mosdns start
sleep 2

if pgrep -x "mosdns" > /dev/null; then
    echo "---------------------------------------"
    echo -e "${GREEN}安装成功!${PLAIN}"
    echo -e "程序版本: $MOSDNS_VERSION"
    echo -e "下载方式: GitHub 直连"
    echo -e "端口: 5335"
    echo -e "测试: dig @127.0.0.1 -p 5335 www.baidu.com"
    echo "---------------------------------------"
else
    err "启动失败，请检查日志: /var/log/mosdns.log"
fi
