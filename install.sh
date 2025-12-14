#!/bin/sh

# ==========================================
# Alpine Linux MosDNS 一键安装脚本 (国内优化版)
# 版本: v5.3.3
# 镜像: gh-proxy.org
# ==========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 变量定义
MOSDNS_VERSION="v5.3.3"
WORK_DIR="/etc/mosdns"
BIN_DIR="/usr/bin"
# === 修改处：更换为 gh-proxy.org ===
GH_PROXY="https://gh-proxy.org/" 

log() {
    echo -e "${GREEN}[Info]${PLAIN} $1"
}

err() {
    echo -e "${RED}[Error]${PLAIN} $1"
    exit 1
}

# 1. 检查 Root 权限
if [ "$(id -u)" != "0" ]; then
    err "请使用 root 用户运行此脚本！"
fi

# 2. 架构检测 (自动适配 amd64 或 arm64)
arch=$(uname -m)
case $arch in
    x86_64)
        MOSDNS_ARCH="amd64"
        ;;
    aarch64)
        MOSDNS_ARCH="arm64"
        ;;
    *)
        err "不支持的架构: $arch"
        ;;
esac
log "检测到架构: $MOSDNS_ARCH"

# 3. 系统环境准备
log "正在配置系统环境 (换阿里云源、安装依赖、设置时区)..."
sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories
apk update
apk add curl wget tar unzip ca-certificates tzdata

cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone
log "系统环境配置完成"

# 4. 下载并安装 MosDNS
log "正在下载 MosDNS ($MOSDNS_VERSION)..."
mkdir -p ${WORK_DIR}
cd /tmp

# 拼接下载链接 (自动匹配架构)
# 最终链接示例: https://gh-proxy.org/https://github.com/IrineSistiana/mosdns/releases/download/v5.3.3/mosdns-linux-arm64.zip
DOWNLOAD_URL="${GH_PROXY}https://github.com/IrineSistiana/mosdns/releases/download/${MOSDNS_VERSION}/mosdns-linux-${MOSDNS_ARCH}.zip"

log "下载链接: $DOWNLOAD_URL"
wget -O mosdns.zip ${DOWNLOAD_URL}

if [ $? -ne 0 ]; then
    err "MosDNS 下载失败，请检查网络或更换加速镜像。"
fi

unzip -o mosdns.zip
# 智能查找二进制文件 (兼容不同版本的解压结构)
if [ -f "mosdns" ]; then
    mv mosdns ${BIN_DIR}/mosdns
elif [ -d "mosdns-linux-${MOSDNS_ARCH}" ]; then
    mv mosdns-linux-${MOSDNS_ARCH}/mosdns ${BIN_DIR}/mosdns
else
    # 深度查找
    find . -type f -name "mosdns" -exec mv {} ${BIN_DIR}/mosdns \;
fi

if [ ! -f "${BIN_DIR}/mosdns" ]; then
    err "解压后未找到 mosdns 二进制文件，安装失败。"
fi

chmod +x ${BIN_DIR}/mosdns
rm -rf mosdns.zip mosdns-linux-*
log "MosDNS 二进制文件安装完成"

# 5. 下载资源文件 (GeoIP / GeoSite)
log "正在下载规则文件 (geoip/geosite)..."
cd ${WORK_DIR}
wget -O geoip.dat "${GH_PROXY}https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
wget -O geosite.dat "${GH_PROXY}https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

if [ ! -f "${WORK_DIR}/geoip.dat" ] || [ ! -f "${WORK_DIR}/geosite.dat" ]; then
    err "规则文件下载失败"
fi
log "规则文件下载完成"

# 6. 生成配置文件
log "正在生成默认配置文件..."
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
log "配置文件已生成"

# 7. 配置 OpenRC 服务
log "配置 OpenRC 开机自启服务..."
cat > /etc/init.d/mosdns <<EOF
#!/sbin/openrc-run

name="mosdns"
description="MosDNS Service"
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
rc-update add mosdns default
log "服务已添加至自启动"

# 8. 启动
log "正在启动 MosDNS..."
service mosdns restart

# 9. 验证
echo "------------------------------------------------"
if pgrep -x "mosdns" > /dev/null; then
    echo -e "${GREEN}MosDNS 安装并启动成功！${PLAIN}"
    echo -e "镜像源: ${GH_PROXY}"
    echo -e "版本: ${MOSDNS_VERSION}"
    echo -e "监听端口: ${YELLOW}5335${PLAIN}"
    echo -e "测试命令: dig @127.0.0.1 -p 5335 www.baidu.com"
else
    echo -e "${RED}启动失败，请查看日志: /var/log/mosdns.log${PLAIN}"
fi
echo "------------------------------------------------"
