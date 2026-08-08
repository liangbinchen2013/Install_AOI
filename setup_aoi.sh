#!/usr/bin/env bash
# =============================================================================
# AOI 在线评测系统 · 一键部署脚本
# -----------------------------------------------------------------------------
# 功能:
#   1. 环境检查 —— 逐项检测系统/依赖/端口/磁盘/内存/网络,详细列出缺失项
#   2. 一键安装 —— 依赖缺失时自动安装(Docker 官方脚本 + 发行版包管理器)
#   3. 自动部署 —— 生成强随机密钥/编排文件/反向代理配置,拉取前端,启动服务
#   4. 简易检查 —— 部署后自动验证(服务状态/API/首页),输出结果清单
#
# 用法:
#   bash setup.sh                     交互模式(缺失依赖时询问是否自动安装)
#   bash setup.sh -y                  全自动(不再询问任何问题)
#   bash setup.sh -d /opt/aoi         指定安装目录(默认 ~/aoi)
#   bash setup.sh --domain aoi.example.com  配置域名(自动启用 HTTPS)
#   bash setup.sh -f                  覆盖已存在的配置文件(重新生成)
#
# 环境变量:
#   AOI_NPM_REGISTRY      npm 镜像,默认 https://registry.npmjs.org
#                         (国内可设: AOI_NPM_REGISTRY=https://registry.npmmirror.com)
#   AOI_SERVER_IMAGE      服务端镜像,默认官方阿里云镜像
#   AOI_REGISTRY_MIRROR   Docker Hub 加速器地址(不设时自动探测多个公共加速器)
#   AOI_MONGO_IMAGE       覆盖 Mongo 镜像(默认 mongo:latest)
#   AOI_CADDY_IMAGE       覆盖 Caddy 镜像(默认 caddy:latest)
#
# 兼容系统: Ubuntu/Debian/CentOS/RHEL/Alma/Rocky/openSUSE/Fedora (x86_64/aarch64)
# Windows 用户请使用 WSL2 或 Linux 服务器运行本脚本。
# =============================================================================

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# 基础配置
# -----------------------------------------------------------------------------
SERVER_IMAGE="${AOI_SERVER_IMAGE:-registry.cn-hangzhou.aliyuncs.com/aoi-js/server:latest}"
NPM_REGISTRY="${AOI_NPM_REGISTRY:-https://registry.npmjs.org}"
MIN_MEM_MB=2048
MIN_DISK_MB=5120

YES=0
FORCE=0
INSTALL_DIR="${HOME}/aoi"
DOMAIN=""
# 探测到的可用镜像加速器 host(如 docker.m.daocloud.io),空 = Docker Hub 直连可用
MIRROR_PREFIX=""

# 颜色输出(非终端自动禁用)
if [ -t 1 ]; then
  C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
  C_CYAN=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_BOLD=''; C_RESET=''
fi

log()  { echo -e "${C_CYAN}[AOI]${C_RESET} $*"; }
info() { echo -e "  ${C_BOLD}$*${C_RESET}"; }
ok()   { echo -e "  ${C_GREEN}✔ $*${C_RESET}"; }
warn() { echo -e "  ${C_YELLOW}⚠ $*${C_RESET}"; }
fail() { echo -e "  ${C_RED}✘ $*${C_RESET}"; }
die()  { echo -e "${C_RED}[错误] $*${C_RESET}" >&2; exit 1; }

# root 用户运行时,内部 sudo 调用直接透传(最小化系统可能没有 sudo 二进制,
# 而 root 本身不需要 sudo;非 root 时仍使用真实的 sudo)
if [ "$(id -u)" -eq 0 ]; then
  sudo() { "$@"; }
fi

usage() {
  cat <<EOF
AOI 在线评测系统一键部署脚本

用法: bash $0 [选项]

选项:
  -y, --yes            全自动模式:不询问,缺失依赖自动安装
  -d, --dir <路径>     安装目录(默认: \$HOME/aoi)
      --domain <域名>  站点域名,配置后自动启用 HTTPS(Caddy 自动签证书)
  -f, --force          覆盖已存在的配置文件(.env / docker-compose.yml / Caddyfile)
  -h, --help           显示本帮助

示例:
  bash $0                      交互模式
  bash $0 -y -d /opt/aoi       全自动安装到 /opt/aoi
  bash $0 -y --domain aoi.example.com

注意:
  安装 Docker / 写入 daemon.json / 启动服务需要 root 权限,
  非 root 用户请用 sudo 运行: sudo bash $0 [选项]
EOF
}

confirm() { # $1=提示文字, 默认 yes
  local answer
  [ "$YES" -eq 1 ] && return 0
  read -r -p "  ${C_BOLD}$1 [Y/n]${C_RESET} " answer
  case "${answer:-y}" in
    y|Y|yes|YES|'') return 0 ;;
    *) return 1 ;;
  esac
}

# -----------------------------------------------------------------------------
# 1. 环境检查
# -----------------------------------------------------------------------------
OS_ID=""; OS_LIKE=""; OS_PRETTY=""

detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-}"; OS_LIKE="${ID_LIKE:-}"; OS_PRETTY="${PRETTY_NAME:-}"
  fi

  case "$(uname -s)" in
    Linux) : ;;
    Darwin)
      die "检测到 macOS:本脚本面向 Linux 服务器(需 Docker),macOS 请使用 Docker Desktop 后手动参考 项目详细.md 第六章部署。"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      die "检测到 Windows 环境($(uname -s)):请改用 WSL2 或 Linux 服务器运行本脚本。"
      ;;
    *)
      die "不支持的系统: $(uname -s)"
      ;;
  esac

  [ -n "$OS_PRETTY" ] && ok "系统: $OS_PRETTY ($(uname -m))"
}

# 依赖检查:把缺失项加入 MISSING 数组
MISSING=()

check_cmd() { # $1=命令  $2=包名/来源说明
  if command -v "$1" >/dev/null 2>&1; then
    ok "$1 已安装"
  else
    fail "$1 缺失(需通过 $2 安装)"
    MISSING+=("$1|$2")
  fi
}

check_docker() {
  if command -v docker >/dev/null 2>&1; then
    local ver
    ver="$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
    ok "Docker 已安装 ($ver)"
    if ! docker info >/dev/null 2>&1; then
      warn "Docker 服务未运行或当前用户无权限(尝试: sudo systemctl start docker; sudo usermod -aG docker \$USER 后重新登录)"
      MISSING+=("docker-running|start docker daemon")
    fi
  else
    fail "Docker 缺失(本脚本将用官方脚本自动安装)"
    MISSING+=("docker|get.docker.com 官方脚本")
  fi
}

check_compose() {
  if docker compose version >/dev/null 2>&1; then
    ok "Docker Compose v2 已安装"
  elif command -v docker-compose >/dev/null 2>&1; then
    warn "检测到旧版 docker-compose(v1),脚本需要 v2 插件,将自动安装"
    MISSING+=("docker-compose-v2|docker compose 插件")
  else
    fail "Docker Compose v2 缺失(将自动安装)"
    MISSING+=("docker-compose-v2|docker compose 插件")
  fi
}

check_port() { # $1=端口  $2=服务名
  local used=0
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}$" && used=1
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}$" && used=1
  fi
  if [ "$used" -eq 1 ]; then
    warn "端口 ${1}($2)已被占用——如果已有反代监听 80/443 可继续,否则后续会失败"
  else
    ok "端口 ${1}($2)可用"
  fi
}

check_resources() {
  # 内存
  local mem_kb=0 mem_mb=0
  [ -r /proc/meminfo ] && mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
  mem_mb=$((mem_kb / 1024))
  if [ "$mem_mb" -ge "$MIN_MEM_MB" ]; then
    ok "内存 ${mem_mb} MB"
  else
    warn "内存仅 ${mem_mb} MB(建议 ≥ ${MIN_MEM_MB} MB,低于建议值 Mongo 可能启动缓慢)"
  fi

  # 磁盘(INSTALL_DIR 所在分区)
  mkdir -p "$INSTALL_DIR" 2>/dev/null || true
  local free_mb=0
  if command -v df >/dev/null 2>&1; then
    free_mb="$(df -mP "$INSTALL_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
    if [ "${free_mb:-0}" -ge "$MIN_DISK_MB" ]; then
      ok "磁盘剩余 ${free_mb} MB"
    else
      warn "磁盘剩余仅 ${free_mb:-未知} MB(建议 ≥ ${MIN_DISK_MB} MB)"
    fi
  fi
}

check_network() {
  local host port
  # 解析 NPM_REGISTRY 的 host(去掉协议前缀)
  host="${NPM_REGISTRY#*://}"; host="${host%%/*}"
  if curl -fsSI --connect-timeout 5 -m 8 "https://${host}" >/dev/null 2>&1; then
    ok "网络可达: ${host}"
  else
    warn "无法访问 ${host}(${NPM_REGISTRY})——前端包下载将失败。国内环境可设 AOI_NPM_REGISTRY=https://registry.npmmirror.com"
  fi

  local img_host="${SERVER_IMAGE%%/*}"
  if curl -fsSI --connect-timeout 5 -m 8 "https://${img_host}" >/dev/null 2>&1; then
    ok "网络可达: ${img_host}"
  else
    warn "无法访问 ${img_host}——拉取服务端镜像可能失败。请确认服务器可访问阿里云容器镜像仓库"
  fi
}

run_checks() {
  info "── 依赖检查 ──────────────────────────────"
  check_cmd curl "curl (apt/yum/dnf/zypper 或 sudo apt install curl)"
  check_cmd tar  "tar"
  check_cmd openssl "openssl(用于生成 JWT 密钥)"
  check_cmd base64 "coreutils(用于生成 JWT 密钥的备用方案)"
  check_docker
  check_compose

  info "── 环境检查 ──────────────────────────────"
  check_port 80 "HTTP 反向代理"
  check_port 443 "HTTPS 反向代理"
  check_port 1926 "AOI server(仅当需直连时关注)"
  check_resources
  check_network
}

# -----------------------------------------------------------------------------
# 2. 自动安装缺失依赖
# -----------------------------------------------------------------------------
apt_has() { apt-get install -y "$@" >/dev/null 2>&1; }

install_missing() {
  [ "${#MISSING[@]}" -eq 0 ] && return 0

  echo
  info "以下依赖缺失,需要自动安装:"
  local i
  for i in "${MISSING[@]}"; do
    info "  - ${i%%|*}: ${i#*|}"
  done
  echo

  if ! confirm "是否现在自动安装这些依赖?"; then
    die "已取消。请手动安装缺失依赖后重新运行本脚本。"
  fi

  # --- 系统包: curl / tar / openssl / base64 ---
  local need_pkgs=()
  for i in "${MISSING[@]}"; do
    case "${i%%|*}" in
      curl|tar|openssl|base64) need_pkgs+=("${i%%|*}") ;;
    esac
  done

  if [ "${#need_pkgs[@]}" -gt 0 ]; then
    local pkg
    case "$OS_ID" in
      ubuntu|debian|linuxmint)
        log "安装系统包: ${need_pkgs[*]} (apt)"
        sudo apt-get update -qq
        sudo apt-get install -y "${need_pkgs[@]}"
        ;;
      centos|rhel|almalinux|rocky|fedora)
        log "安装系统包: ${need_pkgs[*]} (dnf/yum)"
        if command -v dnf >/dev/null 2>&1; then
          sudo dnf install -y "${need_pkgs[@]}"
        else
          sudo yum install -y "${need_pkgs[@]}"
        fi
        ;;
      opensuse*|suse)
        log "安装系统包: ${need_pkgs[*]} (zypper)"
        sudo zypper --non-interactive install "${need_pkgs[@]}"
        ;;
      *)
        warn "不认识的发行版($OS_ID),跳过系统包自动安装,请手动安装: ${need_pkgs[*]}"
        ;;
    esac
  fi

  # --- Docker(官方脚本,带重试与发行版 fallback) ---
  if ! command -v docker >/dev/null 2>&1; then
    local dl_ok=0 retry
    log "安装 Docker(官方 get.docker.com 脚本,最多重试 3 次)..."
    for retry in 1 2 3; do
      if curl -fsSL --connect-timeout 15 -m 300 https://get.docker.com -o /tmp/get-docker.sh && sudo sh /tmp/get-docker.sh; then
        dl_ok=1
        break
      fi
      warn "get.docker.com 安装失败(第 ${retry}/3 次),5 秒后重试..."
      sleep 5
    done
    if [ "$dl_ok" -ne 1 ]; then
      warn "官方脚本不可达,尝试发行版仓库的 docker.io 包..."
      case "$OS_ID" in
        ubuntu|debian|linuxmint)
          sudo apt-get update -qq && sudo apt-get install -y docker.io || die "Docker 安装失败(官方脚本与 apt 仓库均失败),请手动安装 Docker 后重跑本脚本"
          ;;
        *)
          die "Docker 安装失败(官方脚本不可达且当前发行版无自动 fallback),请手动安装 Docker 后重跑本脚本"
          ;;
      esac
    fi
    rm -f /tmp/get-docker.sh
    log "启动 Docker 服务..."
    sudo systemctl enable --now docker >/dev/null 2>&1 || sudo service docker start >/dev/null 2>&1 || true
    # 等待守护进程就绪
    local tries=0
    until sudo docker info >/dev/null 2>&1 || [ "$tries" -ge 15 ]; do sleep 1; tries=$((tries+1)); done
  fi

  # --- Docker Compose v2 插件 ---
  if ! docker compose version >/dev/null 2>&1; then
    log "安装 Docker Compose v2 插件..."
    local arch ok2
    case "$(uname -m)" in x86_64) arch=x86_64 ;; aarch64|arm64) arch=aarch64 ;; *) arch=$(uname -m) ;; esac
    ok2=0
    sudo mkdir -p /usr/local/lib/docker/cli-plugins
    for retry in 1 2 3; do
      if curl -fsSL --connect-timeout 15 -m 180 \
          "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}" \
          -o /tmp/docker-compose && [ -s /tmp/docker-compose ]; then
        sudo install -m 0755 /tmp/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
        rm -f /tmp/docker-compose
        ok2=1
        break
      fi
      warn "Compose 插件下载失败(第 ${retry}/3 次),5 秒后重试..."
      sleep 5
    done
    if [ "$ok2" -ne 1 ]; then
      warn "Compose 插件下载失败(GitHub 可能不可达)。请手动安装 docker compose v2 后重跑本脚本。"
    fi
  fi

  echo
  info "── 重新检查依赖 ──────────────────────────"
  MISSING=()
  check_cmd curl "curl"
  check_cmd tar "tar"
  check_cmd openssl "openssl"
  check_docker
  check_compose
  if [ "${#MISSING[@]}" -gt 0 ]; then
    echo
    die "仍有依赖未解决: $(printf '%s, ' "${MISSING[@]%%|*}")。请手动安装后重新运行。"
  fi
  echo
  ok "所有依赖已就绪"
}

# -----------------------------------------------------------------------------
# 3. 生成配置文件
# -----------------------------------------------------------------------------
gen_env() {
  [ "$FORCE" -eq 0 ] && [ -f .env ] && { warn "已存在 .env,跳过(如需重置请加 -f 或手动删除)"; return; }
  local secret
  if command -v openssl >/dev/null 2>&1; then
    secret="$(openssl rand -base64 48 | tr -d '\n')"
  elif command -v base64 >/dev/null 2>&1; then
    secret="$(head -c 48 /dev/urandom | base64 | tr -d '\n')"
  else
    secret="aoi-$(date +%s)-$$"
    warn "无法生成强随机密钥,已使用临时值。请尽快手动编辑 .env 替换为强随机串(≥32字节)"
  fi
  cat > .env <<EOF
# AOI 部署配置(含密钥,勿提交到版本库)
# 密钥用于 JWT 签名(HS256),泄露/过弱可导致任意账号被伪造,请务必保持随机
AOI_JWT_SECRET=${secret}
EOF
  chmod 600 .env
  ok ".env 已生成(密钥 ${#secret} 字节)"
}

gen_compose() {
  [ "$FORCE" -eq 0 ] && [ -f docker-compose.yml ] && { warn "已存在 docker-compose.yml,跳过"; return; }
  # 默认镜像:用户显式指定 > 加速器前缀直拉(Docker Hub 不可达时)> docker.io 官方地址
  local mongo_img="${AOI_MONGO_IMAGE:-}"
  local caddy_img="${AOI_CADDY_IMAGE:-}"
  [ -z "$mongo_img" ] && mongo_img="$([ -n "$MIRROR_PREFIX" ] && echo "${MIRROR_PREFIX}/library/mongo:latest" || echo "mongo:latest")"
  [ -z "$caddy_img" ] && caddy_img="$([ -n "$MIRROR_PREFIX" ] && echo "${MIRROR_PREFIX}/library/caddy:latest" || echo "caddy:latest")"
  cat > docker-compose.yml <<EOF
version: '3.8'

services:
  # AOI API 服务器(端口 1926,不直接对外)
  server:
    image: ${SERVER_IMAGE}
    expose:
      - '1926'
    environment:
      - AOI_MONGO_URL=mongodb://mongo:27017/aoi
      - AOI_JWT_SECRET=\${AOI_JWT_SECRET}
      # - AOI_REDIS_URL=redis://redis:6379/0   # 多实例/高并发建议启用 Redis
      # - AOI_AUTH_PROVIDERS=password,mail     # 启用邮箱登录见 项目详细.md 6.7
      # - AOI_SIGNUP_ENABLED=true
      # - AOI_LOG_LEVEL=info
    depends_on:
      - mongo
    restart: unless-stopped

  # 比赛状态更新器(官方方案易遗漏!负责比赛 PENDING/RUNNING/ENDED 状态流转)
  updater:
    image: ${SERVER_IMAGE}
    command: node lib/cli/updater.js
    environment:
      - AOI_MONGO_URL=mongodb://mongo:27017/aoi
    depends_on:
      - mongo
    restart: unless-stopped

  # MongoDB(数据持久化到 ./mongo)
  mongo:
    image: ${mongo_img}
    volumes:
      - ./mongo:/data/db
    expose:
      - '27017'
    restart: unless-stopped

  # 反向代理 + 前端静态服务(Caddy)
  caddy:
    image: ${caddy_img}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - ./frontend:/var/www/html
      - ./caddy-data:/data
      - ./caddy-config:/config
    ports:
      - '80:80'
      - '443:443'
    depends_on:
      - server
    restart: unless-stopped
EOF
  ok "docker-compose.yml 已生成(server + updater + mongo + caddy)"
}

gen_caddyfile() {
  [ "$FORCE" -eq 0 ] && [ -f Caddyfile ] && { warn "已存在 Caddyfile,跳过"; return; }
  if [ -n "$DOMAIN" ]; then
    cat > Caddyfile <<EOF
${DOMAIN} {
    encode gzip
    handle /api/* {
        reverse_proxy server:1926
    }
    handle {
        root * /var/www/html
        try_files {path} /index.html
        file_server
    }
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "no-referrer"
    }
}
EOF
    ok "Caddyfile 已生成(域名 ${DOMAIN},自动 HTTPS)"
  else
    cat > Caddyfile <<EOF
:80 {
    handle /api/* {
        reverse_proxy server:1926
    }
    handle {
        root * /var/www/html
        try_files {path} /index.html
        file_server
    }
    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "no-referrer"
    }
}
EOF
    ok "Caddyfile 已生成(HTTP 模式;如需 HTTPS,用 --domain 重新执行或改 Caddyfile 首行为域名)"
  fi
}

fetch_frontend() {
  [ -f frontend/index.html ] && { ok "前端已存在(frontend/index.html),跳过下载"; return; }

  log "获取 @aoi-js/frontend 最新版信息(源: ${NPM_REGISTRY})..."
  local meta url
  meta="$(curl -fsSL --connect-timeout 10 -m 30 "${NPM_REGISTRY}/@aoi-js/frontend/latest" 2>/dev/null || true)"
  if [ -z "$meta" ]; then
    die "无法获取前端包信息。国内环境请用: AOI_NPM_REGISTRY=https://registry.npmmirror.com bash setup.sh"
  fi
  url="$(printf '%s' "$meta" | grep -oE '"tarball":"[^"]+"' | head -1 | cut -d'"' -f4)"
  [ -n "$url" ] || die "解析前端包下载地址失败"

  log "下载前端包: $url"
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL --connect-timeout 10 -m 300 "$url" -o "$tmp/frontend.tgz" || { rm -rf "$tmp"; die "前端包下载失败"; }
  mkdir -p "$tmp/x" frontend
  tar -xzf "$tmp/frontend.tgz" -C "$tmp/x"
  if [ -d "$tmp/x/package/dist" ]; then
    cp -r "$tmp/x/package/dist/." frontend/
  else
    rm -rf "$tmp" frontend
    die "前端包解压结构异常(未找到 package/dist)"
  fi
  rm -rf "$tmp"
  [ -f frontend/index.html ] || die "前端解压后缺少 index.html"
  ok "前端已就绪($(find frontend -type f | wc -l) 个文件)"
}

# -----------------------------------------------------------------------------
# 4. 启动与自动验证
# -----------------------------------------------------------------------------
# 探测 Docker Hub 可达性;不可达时探测候选镜像加速器,选中结果记入 MIRROR_PREFIX
# 可用环境变量 AOI_REGISTRY_MIRROR 手动指定加速器地址
probe_registry_mirror() {
  [ -n "$MIRROR_PREFIX" ] && return 0
  if [ -n "${AOI_REGISTRY_MIRROR:-}" ]; then
    MIRROR_PREFIX="${AOI_REGISTRY_MIRROR#*://}"; MIRROR_PREFIX="${MIRROR_PREFIX%%/*}"
    info "使用指定加速器: ${MIRROR_PREFIX}"
    return 0
  fi
  if curl -sSI --connect-timeout 5 -m 8 "https://registry-1.docker.io/v2/" >/dev/null 2>&1; then
    info "Docker Hub 直连可用,无需镜像加速器"
    return 0
  fi
  warn "Docker Hub 不可达(国内网络常见),探测可用的镜像加速器..."
  local m mhost code
  for m in \
    "https://docker.m.daocloud.io" \
    "https://docker.1ms.run" \
    "https://hub.rat.dev" \
    "https://docker.1panel.live"; do
    mhost="${m#*://}"; mhost="${mhost%%/*}"
    code="$(curl -sSI --connect-timeout 5 -m 8 "https://${mhost}" -o /dev/null -w '%{http_code}' 2>/dev/null || true)"
    if [ -n "$code" ] && [ "$code" != "000" ]; then
      MIRROR_PREFIX="$mhost"
      ok "选中加速器: ${mhost} (HTTP ${code})"
      return 0
    fi
    warn "加速器不可用: $m"
  done
  warn "所有候选加速器均不可达——稍后容器启动可能失败"
  warn "请设置 AOI_REGISTRY_MIRROR 指定可用加速器,或用 AOI_MONGO_IMAGE / AOI_CADDY_IMAGE 指定可直接访问的镜像"
  return 1
}

# 把探测到的加速器写入 /etc/docker/daemon.json(仅当 Docker Hub 不可达时)
configure_registry_mirror() {
  [ -z "$MIRROR_PREFIX" ] && return 0
  if ! command -v docker >/dev/null 2>&1; then return 0; fi
  local picked="https://${MIRROR_PREFIX}"

  local djson="/etc/docker/daemon.json"
  if [ -f "$djson" ] && grep -q 'registry-mirrors' "$djson" 2>/dev/null; then
    warn "daemon.json 已包含 registry-mirrors,跳过写入(已验证可用: ${picked})"
  elif [ -f "$djson" ] && [ -s "$djson" ] && ! grep -qE '^\s*\{\s*\}$' "$djson"; then
    warn "daemon.json 已有其他配置,请手动合并以下内容后重启 docker:"
    warn "  { \"registry-mirrors\": [\"${picked}\"] }"
    return 1
  else
    sudo tee "$djson" > /dev/null <<EOF
{
  "registry-mirrors": ["${picked}"]
}
EOF
    ok "已写入 daemon.json 加速器: ${picked}"
  fi

  sudo systemctl restart docker >/dev/null 2>&1 || sudo service docker restart >/dev/null 2>&1 || true
  sleep 3
  if docker pull --quiet hello-world >/dev/null 2>&1; then
    docker image rm hello-world >/dev/null 2>&1 || true
    ok "镜像加速器验证通过(可正常拉取镜像)"
  else
    warn "镜像加速器已配置,但验证拉取未通过——请检查网络后重试"
  fi
}

# daemon 镜像加速器仍不稳定时,把 mongo/caddy 换成加速器前缀直拉地址
# (如 docker.m.daocloud.io/library/mongo:latest,绕开 Docker Hub 认证流,国内更稳)
switch_to_mirror_prefix_images() {
  local mirror host prefix changed=0
  mirror="$(grep -oE '"https://[^"]+"' /etc/docker/daemon.json 2>/dev/null | head -1 | tr -d '"' || true)"
  [ -z "$mirror" ] && mirror="${AOI_REGISTRY_MIRROR:-}"
  [ -z "$mirror" ] && return 1
  host="${mirror#*://}"; host="${host%%/*}"
  prefix="${host}/library"

  if grep -q 'image: mongo:latest' docker-compose.yml 2>/dev/null; then
    sed -i "s#image: mongo:latest#image: ${prefix}/mongo:latest#" docker-compose.yml
    changed=1
  fi
  if grep -q 'image: caddy:latest' docker-compose.yml 2>/dev/null; then
    sed -i "s#image: caddy:latest#image: ${prefix}/caddy:latest#" docker-compose.yml
    changed=1
  fi
  if [ "$changed" -eq 1 ]; then
    ok "docker-compose.yml 已切换镜像源为 ${prefix}/... (加速器前缀直拉)"
  fi
  return $((1 - changed))
}

# 列出 docker-compose.yml 中本地缺失的镜像(每行一个);输出为空 = 全部已在本地
# 含变量(${...})的 image 行无法静态检查,直接跳过
compose_missing_images() {
  [ -f docker-compose.yml ] || return 0
  grep -oE 'image: [^ ]+' docker-compose.yml \
    | sed 's/^image: *//' \
    | grep -v '\${' \
    | while read -r img; do
        [ -n "$img" ] || continue
        docker image inspect "$img" >/dev/null 2>&1 || echo "$img"
      done || true
}

compose_up() {
  local tries=1 missing
  missing="$(compose_missing_images)"
  if [ -z "$missing" ]; then
    info "所需镜像均已存在本地,跳过网络拉取"
    if docker compose up -d --pull never; then
      echo
      ok "容器已启动(全部使用本地镜像)"
      return 0
    fi
    warn "当前 Compose 版本不支持 --pull never,改用默认策略重试(本地已有镜像时同样不会联网拉取)"
  else
    info "本地缺少镜像: $(echo "$missing" | tr '\n' ' ')"
    log "启动容器(docker compose up -d,仅拉取缺失的镜像)..."
  fi
  while [ "$tries" -le 3 ]; do
    if docker compose up -d; then
      echo
      ok "容器已启动"
      return 0
    fi
    if [ "$tries" -lt 3 ]; then
      warn "容器启动失败(第 ${tries}/3 次),10 秒后重试..."
      # 镜像全在本地时不要改动镜像源(改动后反而需要联网拉新镜像)
      [ -z "$missing" ] || switch_to_mirror_prefix_images || true
      sleep 10
    fi
    tries=$((tries+1))
  done
  echo
  warn "多次启动失败,容器未完全就绪。可执行: docker compose logs server / caddy / mongo 排查"
}

wait_ready() {
  log "等待服务就绪(最多 120 秒)..."
  local i
  for i in $(seq 1 60); do
    if curl -fsS --connect-timeout 3 -m 5 "http://127.0.0.1/api/ping" >/dev/null 2>&1; then
      echo
      ok "API 已就绪(耗时约 $((i * 2)) 秒)"
      return 0
    fi
    sleep 2
  done
  echo
  warn "服务尚未就绪(超时)。请执行: docker compose logs server 查看错误"
  return 1
}

run_post_checks() {
  echo
  info "── 部署后自动检查 ────────────────────────"
  local pass=0 total=0

  # 1. 容器状态
  total=$((total+1))
  local running
  running="$(docker compose ps --status running -q 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${running:-0}" -ge 4 ]; then
    ok "容器状态: ${running}/4 个运行中"
    pass=$((pass+1))
  else
    fail "容器未全部启动(${running:-0}/4),请查看 docker compose ps 与 docker compose logs"
  fi

  # 2. API ping
  total=$((total+1))
  if curl -fsS --connect-timeout 5 -m 8 "http://127.0.0.1/api/ping" >/dev/null 2>&1; then
    ok "API 健康检查 /api/ping 通过"
    pass=$((pass+1))
  else
    fail "/api/ping 失败"
  fi

  # 3. 首页
  total=$((total+1))
  local ct
  ct="$(curl -fsSI --connect-timeout 5 -m 8 "http://127.0.0.1/" 2>/dev/null | grep -i '^content-type:' || true)"
  if echo "$ct" | grep -qi 'text/html'; then
    ok "首页可访问(text/html)"
    pass=$((pass+1))
  else
    fail "首页响应异常(${ct:-无响应})"
  fi

  # 4. server 日志无致命错误
  total=$((total+1))
  if docker compose logs server 2>/dev/null | tail -100 | grep -qiE 'fatal|error: missing env|uncaught'; then
    fail "server 日志出现错误(见上方 docker compose logs server)"
  else
    ok "server 日志无致命错误"
    pass=$((pass+1))
  fi

  echo
  if [ "$pass" -eq "$total" ]; then
    ok "全部 ${total} 项检查通过"
  else
    warn "${pass}/${total} 项通过,请根据失败项排查"
  fi
}

# -----------------------------------------------------------------------------
# 5. 总结与下一步
# -----------------------------------------------------------------------------
print_summary() {
  local url="http://localhost/"
  [ -n "$DOMAIN" ] && url="https://${DOMAIN}/"

  cat <<EOF

${C_GREEN}${C_BOLD}════════════════════════════════════════════════════════════${C_RESET}
${C_GREEN}${C_BOLD}  AOI 部署完成!访问地址: ${url}${C_RESET}
${C_GREEN}${C_BOLD}════════════════════════════════════════════════════════════${C_RESET}

${C_BOLD}接下来的 4 步:${C_RESET}

1) 打开上面地址,${C_BOLD}注册一个账号${C_RESET}(如果注册页未显示请刷新)

2) 把该账号设为系统管理员(脚本已无需猜容器名,用 compose 别名):
   cd ${INSTALL_DIR}
   docker compose exec mongo mongosh --quiet <<'CMD'
use aoi
db.users.updateOne({'profile.name':'你的用户名'}, { \$set: { capability: Long(-1) } })
CMD
   (把 '你的用户名' 替换成刚注册的用户名。Long(-1) = 全部权限位)

3) 刷新页面,左侧出现 Global Admin 菜单即成功。

4) 创建组织后,在组织 Admin → Settings 里${C_BOLD}配置对象存储 OSS${C_RESET}
   (bucket / endpoint / accessKey / secretKey),否则提交代码与题目数据无法上传。

${C_BOLD}常用管理命令:${C_RESET}
   cd ${INSTALL_DIR}
   docker compose ps                 # 查看容器状态
   docker compose logs -f server     # 跟踪服务日志
   docker compose logs -f caddy      # 跟踪反代日志
   docker compose down               # 停止
   docker compose up -d              # 启动
   备份: docker compose exec mongo mongodump --archive > backup-\$(date +%F).archive

${C_BOLD}安全提醒:${C_RESET}
   • JWT 密钥已随机生成并写入 .env(权限 600),请勿提交到 git
   • 本脚本未配置 HTTPS(未指定 --domain 时);公网部署建议用 --domain 重新执行
   • 1926 端口未对公网开放,所有流量经 Caddy 反代
   • 评测机(runner)不包含在本脚本中,需另行接入

${C_YELLOW}提示: 重复运行本脚本是安全的(已存在的文件会跳过,本地已有的镜像不会再次联网拉取;加 -f 强制覆盖)。${C_RESET}
EOF
}

# -----------------------------------------------------------------------------
# 主流程
# -----------------------------------------------------------------------------
main() {
  # 参数解析
  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes) YES=1 ;;
      -f|--force) FORCE=1 ;;
      -d|--dir) INSTALL_DIR="$2"; shift ;;
      --domain) DOMAIN="$2"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数: $1(用 -h 查看帮助)" ;;
    esac
    shift
  done

  # 0) 权限检查
  # 安装 Docker / 写入 daemon.json / 启动服务都需要 root 权限;
  # 非 root 且系统没有 sudo 时无法继续,直接提示用户改用 root 或 sudo 运行
  if [ "$(id -u)" -eq 0 ]; then
    ok "权限: 以 root 运行"
  elif command -v sudo >/dev/null 2>&1; then
    ok "权限: 已检测到 sudo(需要时会自动以 sudo 执行系统操作)"
  else
    echo
    die "当前用户无 root 权限且系统中未安装 sudo,无法继续安装。请以 root 用户登录,或先安装 sudo(如 apt install sudo / dnf install sudo)后重新运行: sudo bash $0 $*"
  fi

  cat <<EOF
${C_BOLD}┌──────────────────────────────────────────────────┐${C_RESET}
${C_BOLD}│   AOI 在线评测系统 · 一键部署脚本              │${C_RESET}
${C_BOLD}│   安装目录: ${INSTALL_DIR}${C_RESET}
${C_BOLD}│   域名: ${DOMAIN:-<无,HTTP 模式>}${C_RESET}
${C_BOLD}└──────────────────────────────────────────────────┘${C_RESET}
EOF

  # 1) 检查环境
  detect_os
  run_checks
  echo
  if [ "${#MISSING[@]}" -gt 0 ]; then
    info "共检测到 ${#MISSING[@]} 项依赖缺失:"
    local i
    for i in "${MISSING[@]}"; do
      info "  - ${i%%|*}: ${i#*|}"
    done
    echo
  fi

  # 2) 自动安装缺失依赖
  install_missing

  # 3) 生成配置并部署
  echo
  info "── 生成配置文件 ──────────────────────────"
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR" || die "无法进入安装目录 $INSTALL_DIR"

  # 已部署过(compose 文件存在且所需镜像均在本地)时不再访问网络拉取镜像,
  # 跳过加速器探测/写入 daemon.json/验证拉取等一切联网操作
  ALL_LOCAL=0
  if [ -f docker-compose.yml ] && [ -z "$(compose_missing_images)" ]; then
    ALL_LOCAL=1
    ok "检测到已部署环境:所需镜像均在本地,本次不会访问网络拉取镜像"
  fi
  [ "$ALL_LOCAL" -eq 1 ] || probe_registry_mirror || true

  gen_env
  gen_compose
  gen_caddyfile
  fetch_frontend

  echo
  info "── 启动服务 ──────────────────────────────"
  [ "$ALL_LOCAL" -eq 1 ] || configure_registry_mirror || true
  compose_up
  wait_ready

  # 4) 自动简易检查
  run_post_checks

  # 5) 总结
  print_summary
}

main "$@"
