#!/bin/sh

# ==========================================
# Alpine Linux MosDNS 一键安装脚本 (国内优化版)
# ==========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 变量定义
MOSDNS_VERSION="v5.3.1" # 指定版本，确保稳定性
WORK_DIR="/etc/mosdns"
BIN_DIR="/usr/bin"
GH_PROXY="https://ghfast.top/" # GitHub 加速镜像

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

# 2. 架构检测
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

# 3. 系统环境准备 (换源 & 安装依赖 & 设置时区)
log "正在配置系统环境 (换阿里云源、安装依赖、设置时区)..."
sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories
apk update
apk add curl wget tar unzip ca-certificates tzdata

# 设置时区为上海
cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone
log "系统环境配置完成"

# 4. 下载并安装 MosDNS
log "正在下载 MosDNS ($MOSDNS_VERSION)..."
mkdir -p ${WORK_DIR}
cd /tmp

DOWNLOAD_URL="${GH_PROXY}https://github.com/IrineSistiana/mosdns/releases/download/v5.3.3/mosdns-linux-arm64.zip"

wget -O mosdns.zip ${DOWNLOAD_URL}
if [ $? -ne 0 ]; then
    err "MosDNS 下载失败，请检查网络或更换加速镜像。"
fi

unzip -o mosdns.zip
mv mosdns ${BIN_DIR}/mosdns
chmod +x ${BIN_DIR}/mosdns
rm -f mosdns.zip
log "MosDNS 二进制文件安装完成"

# 5. 下载资源文件 (GeoIP / GeoSite)
log "正在下载规则文件 (geoip/geosite)..."
cd ${WORK_DIR}
wget -O geoip.dat "${GH_PROXY}https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat"
wget -O geosite.dat "${GH_PROXY}https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat"

if [ ! -f "${WORK_DIR}/geoip.dat" ] || [ ! -f "${WORK_DIR}/geosite.dat" ]; then
    err "规则文件下载失败"
fi
log "规则文件下载完成"

# 6. 生成配置文件 (config.yaml)
log "正在生成默认配置文件..."
cat > ${WORK_DIR}/config.yaml <<EOF
log:
  level: info
  file: "/var/log/mosdns.log"

plugins:
  # 缓存插件
  - tag: cache
    type: cache
    args:
      size: 10240
      lazy_cache_ttl: 86400

  # 国内 DNS (阿里 DNS)
  - tag: forward_local
    type: forward
    args:
      upstreams:
        - addr: "223.5.5.5"
        - addr: "119.29.29.29"

  # 国外 DNS (Google/Cloudflare)
  # 如果你有本地代理端口，请修改这里，例如: "127.0.0.1:1053"
  - tag: forward_remote
    type: forward
    args:
      upstreams:
        - addr: "8.8.8.8"
        - addr: "1.1.1.1"

  # 分流逻辑
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
      # 非 CN 域名走远程
      - exec: \$forward_remote

servers:
  - exec: main_sequence
    listeners:
      - protocol: udp
        addr: ":5335" # 监听 5335，避免冲突
      - protocol: tcp
        addr: ":5335"
EOF
log "配置文件已生成: ${WORK_DIR}/config.yaml"

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

# 8. 启动服务
log "正在启动 MosDNS..."
service mosdns restart

# 9. 验证安装
echo "------------------------------------------------"
if pgrep -x "mosdns" > /dev/null; then
    echo -e "${GREEN}MosDNS 安装并启动成功！${PLAIN}"
    echo -e "配置文件路径: ${YELLOW}${WORK_DIR}/config.yaml${PLAIN}"
    echo -e "监听端口: ${YELLOW}5335${PLAIN}"
    echo -e "你可以使用以下命令测试:"
    echo -e "dig @127.0.0.1 -p 5335 www.baidu.com"
else
    echo -e "${RED}MosDNS 启动失败，请查看日志: /var/log/mosdns.log${PLAIN}"
fi
echo "------------------------------------------------"
