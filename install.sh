#!/bin/sh

# ==========================================
# Alpine MosDNS 故障修复脚本 (GitHub 直连版)
# 模式: 无加速，直接连接 GitHub
# 目标: 修复 "invalid keys: servers" 报错
# ==========================================

# 1. 遇到错误立即停止
set -e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 变量
MOSDNS_VERSION="v5.3.3"
WORK_DIR="/etc/mosdns"
BIN_DIR="/usr/bin"

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

# === 第一步：彻底清理旧版本 (修复核心) ===
log "正在停止服务并清理旧版本..."
service mosdns stop 2>/dev/null || true
killall mosdns 2>/dev/null || true

# [重要] 卸载系统自带的旧版 mosdns (如果有)
apk del mosdns 2>/dev/null || true

# 强制删除可能存在的旧二进制文件
rm -f "${BIN_DIR}/mosdns"
rm -rf /tmp/mosdns*

# === 第二步：基础环境 ===
log "配置基础依赖..."
# 保留阿里云源以确保 curl/wget 能装上
sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories
apk update || true
apk add curl wget tar unzip ca-certificates tzdata

cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime 2>/dev/null || true

# === 第三步：下载 MosDNS v5 (GitHub 直连) ===
log "正在下载 MosDNS ${MOSDNS_VERSION} (直连 GitHub，可能较慢)..."
cd /tmp

# 直连 URL
URL="https://github.com/IrineSistiana/mosdns/releases/download/${MOSDNS_VERSION}/mosdns-linux-${ARCH}.zip"
log "下载地址: $URL"

# 增加参数: -T 30 (30秒超时), -t 5 (重试5次), --no-check-certificate (防止证书报错)
if ! wget --no-check-certificate -T 30 -t 5 -O mosdns.zip "$URL"; then
    err "下载失败！直连 GitHub 超时或连接被重置。请检查网络或恢复使用镜像加速。"
fi

# 检查文件大小 (防止下载到 0KB 空文件)
if [ ! -s mosdns.zip ]; then
    err "下载的文件为空！下载失败。"
fi

# === 第四步：安装并验证版本 ===
log "正在安装..."
unzip -o mosdns.zip > /dev/null

# 智能查找
if [ -f "mosdns" ]; then
    mv mosdns ${BIN_DIR}/mosdns
elif [ -d "mosdns-linux-${ARCH}" ]; then
    mv mosdns-linux-${ARCH}/mosdns ${BIN_DIR}/mosdns
else
    find . -type f -name "mosdns" -exec mv {} ${BIN_DIR}/mosdns \;
fi

chmod +x ${BIN_DIR}/mosdns

# [关键验证] 必须确保是 v5 版本
log "正在验证版本..."
CURRENT_VER=$(${BIN_DIR}/mosdns version 2>/dev/null || echo "Error")
log "当前版本: $CURRENT_VER"

if echo "$CURRENT_VER" | grep -q "v5"; then
    log "版本验证通过 (v5)！"
else
    rm -f ${BIN_DIR}/mosdns
    err "严重错误：下载的版本不正确或文件损坏，无法运行 v5 配置。请检查网络。"
fi

# === 第五步：下载规则文件 (GitHub 直连) ===
log "下载规则文件 (直连)..."
mkdir -p ${WORK_DIR}
cd ${WORK_DIR}
rm -f geoip.dat geosite.dat

wget --no-check-certificate -T 30 -t 5 -O geoip.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
wget --no-check-certificate -T 30 -t 5 -O geosite.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

# === 第六步：生成配置 ===
log "重新生成 config.yaml..."
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

# === 第七步：配置服务 ===
cat > /etc/init.d/mosdns <<EOF
#!/sbin/openrc-run
name="mosdns"
command="${BIN_DIR}/mosdns"
command_args="start -c ${WORK_DIR}/config.yaml -d ${WORK_DIR}"
command_background=true
pidfi
