#!/usr/bin/env bash
# =============================================================================
# Azukiiro 评测机 · 一键部署脚本
# -----------------------------------------------------------------------------
# 功能:
#   1. 环境检查 —— 系统/依赖(网络可达性、unzip、可选 deno/docker)
#   2. 一键安装 —— 从 GitHub Releases 下载 azukiiro 二进制(自动匹配架构)
#   3. 自动配置 —— 生成配置文件并注册到 AOI Server(runnerId/runnerKey)
#   4. 注册系统服务 —— systemd 单元(azukiiro@daemon / @ranker / @instancer)
#   5. 简易检查 —— 服务状态、azukiiro info、配置回读
#
# 用法:
#   bash setup_azukiiro.sh                        交互模式(询问服务器地址与注册令牌)
#   bash setup_azukiiro.sh -y                     全自动(需配合 -s / -t,不询问)
#   bash setup_azukiiro.sh -s http://localhost/ -t <registrationToken> [-l default,ranker]
#   bash setup_azukiiro.sh --ranker --db mongodb://127.0.0.1:27017/aoi   # 同时启用排行榜
#   bash setup_azukiiro.sh --instancer            # 同时启用沙箱实例(需 Docker + caddy 网络)
#   bash setup_azukiiro.sh -f                     # 强制重新注册/覆盖配置
#
# 环境变量:
#   AZUKIIRO_VERSION    指定版本号(默认 latest,如 v1.2.3)
#   AZUKIIRO_BASE_URL   下载基址(默认 GitHub Releases latest/download;
#                       国内镜像可设如 https://mirror.ghproxy.com/https://github.com/...)
#   AZUKIIRO_LABELS     默认注册标签(默认 default)
#
# 兼容系统: Ubuntu/Debian/CentOS/RHEL/Alma/Rocky/openSUSE/Fedora (x86_64/aarch64)
# Windows 用户请使用 WSL2 或 Linux 服务器运行本脚本。
# =============================================================================

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# 基础配置
# -----------------------------------------------------------------------------
INSTALL_DIR="/opt/azukiiro"
CONFIG_DIR="/etc/azukiiro"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
STORAGE_PATH="/var/lib/azukiiro"
SERVICE_USER="azukiiro"

# 未显式指定下载基址时: 指定了版本 → releases/download/<版本>;否则 latest/download
if [ -n "${AZUKIIRO_BASE_URL:-}" ]; then
  BASE_URL="$AZUKIIRO_BASE_URL"
elif [ -n "${AZUKIIRO_VERSION:-}" ] && [ "$AZUKIIRO_VERSION" != "latest" ]; then
  BASE_URL="https://github.com/fedstackjs/azukiiro/releases/download/${AZUKIIRO_VERSION}"
else
  BASE_URL="https://github.com/fedstackjs/azukiiro/releases/latest/download"
fi
# 注意: 不能用 VERSION 做变量名——detect_os 里 source 的 /etc/os-release 也会定义 VERSION(如 "24.04.4 LTS"),会被覆盖
REQ_VERSION="${AZUKIIRO_VERSION:-latest}"
DEFAULT_LABELS="${AZUKIIRO_LABELS:-default}"

SERVER_ADDR=""
REG_TOKEN=""
RUNNER_NAME=""
RUNNER_LABELS="$DEFAULT_LABELS"
DB_ADDR=""
YES=0
FORCE=0
REBIND=0
ENABLE_RANKER=0
ENABLE_INSTANCER=0
ENABLE_UOJ=0

# 颜色输出(非终端自动禁用)
if [ -t 1 ]; then
  C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
  C_CYAN=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_BOLD=''; C_RESET=''
fi

log()  { echo -e "${C_CYAN}[AZUKIIRO]${C_RESET} $*"; }
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
Azukiiro 评测机(AOI 官方 runner)一键部署脚本

用法: bash $0 [选项]

必填选项(注册到 AOI Server):
  -s, --server <地址>   AOI Server 地址(如 http://localhost/ 或 http://192.168.1.10/)
                        --ranker 模式还需 --db 提供 MongoDB 连接串
  -t, --token <令牌>    组织管理员在 Runner 管理页生成的 registrationToken(5 分钟有效)
                        交互模式下留空则运行时询问

其他选项:
  -n, --name <名称>     runner 名称(默认取主机名)
  -l, --labels <标签>   逗号分隔标签(默认: $DEFAULT_LABELS)
                        注意: 评测机只能领取 label 与其匹配的提交,
                        即 runner 标签需包含题目 problem.json 的 label!
                        --ranker 会自动追加 ranker;--instancer 会自动追加 instance:*
  -d, --dir <路径>      安装目录(默认: $INSTALL_DIR)
      --ranker         同时启用排行榜守护进程(需 --db 提供 MongoDB 地址)
      --db <MongoURI>  MongoDB 连接串,如 mongodb://127.0.0.1:27017/aoi(一般复用 AOI 的 Mongo)
      --instancer      同时启用沙箱实例守护进程(需本机 Docker + 外部 caddy 网络)
      --with-uoj       安装 uoj 适配器所需 bwrap 沙箱(还需自行部署 /opt/uoj_judger)
  -y, --yes            全自动模式:不询问任何问题
  -f, --force          强制覆盖已有配置(保留凭据,重新注册)
      --rebind         重新绑定: 清除本地旧凭据并强制重新注册(需新的 registrationToken)
                       换服务器/换组织/轮换 runnerKey 时使用;AOI 前端 Runner 页的
                       旧 runner 记录不会自动删除,请手动清理
  -h, --help           显示本帮助

示例:
  bash $0 -y -s http://localhost/ -t \$(cat token.txt)
  bash $0 -s http://192.168.1.5/ --ranker --db mongodb://127.0.0.1:27017/aoi
  bash $0 -s http://localhost/ -l default,ranker
  bash $0 --rebind -s http://新服务器/ -t \$(cat token.txt) -l default,ranker   # 重新绑定

注意:
  写 /etc/azukiiro / 创建系统用户 / 安装 systemd 服务需要 root 权限,
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
      die "检测到 macOS:本脚本面向 Linux 服务器(评测沙箱依赖 Linux),macOS 请改用 Linux/WSL2。"
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

MISSING=()

check_cmd() { # $1=命令  $2=包名/来源说明
  if command -v "$1" >/dev/null 2>&1; then
    ok "$1 已安装"
  else
    fail "$1 缺失(需通过 $2 安装)"
    MISSING+=("$1|$2")
  fi
}

check_github() {
  local host="${BASE_URL#*://}"; host="${host%%/*}"
  if curl -fsSI --connect-timeout 5 -m 8 "https://${host}" >/dev/null 2>&1; then
    ok "网络可达: ${host}(二进制下载源)"
  else
    warn "无法访问 ${host}——下载 azukiiro 二进制将失败。"
    warn "国内环境可设 AZUKIIRO_BASE_URL 指向镜像,如:"
    warn "  AZUKIIRO_BASE_URL=https://mirror.ghproxy.com/https://github.com/fedstackjs/azukiiro/releases/latest/download"
  fi
}

check_docker() { # 仅 --instancer 时调用
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    ok "Docker 可用(instancer 依赖)"
  else
    warn "Docker 未就绪——--instancer 将无法使用。请先安装并启动 Docker 后重试。"
    if ! confirm "Docker 不可用,是否跳过沙箱实例部分,只部署评测/排榜?"; then
      die "已取消。请先安装 Docker: curl -fsSL https://get.docker.com | sudo sh"
    fi
    ENABLE_INSTANCER=0
  fi
  if command -v docker >/dev/null 2>&1 && ! docker network inspect caddy >/dev/null 2>&1; then
    warn "未检测到名为 caddy 的 Docker 外部网络——instancer 要求题目 compose 环境接入 caddy 网络。"
    warn "创建命令: docker network create caddy(需与 AOI 反代同网络,见 项目详细.md 部署章节)"
  fi
}

check_deno() { # deno 适配器可选依赖,仅提示
  if command -v deno >/dev/null 2>&1; then
    ok "deno 已安装(deno 适配器可用)"
  else
    warn "deno 未安装——若题目使用 deno 适配器将评测失败。安装: curl -fsSL https://deno.land/install.sh | sh"
  fi
}

run_checks() {
  info "── 依赖检查 ──────────────────────────────"
  check_cmd curl "curl (apt/yum/dnf/zypper)"
  check_cmd tar  "tar"
  check_cmd unzip "unzip(评测解压数据必需)"
  check_cmd find "find (coreutils)"
  check_github

  info "── 可选依赖 ──────────────────────────────"
  check_deno
  [ "$ENABLE_INSTANCER" -eq 1 ] && check_docker

  info "── 参数检查 ──────────────────────────────"
  [ -z "$SERVER_ADDR" ] && { [ "$YES" -eq 1 ] && die "全自动模式(-y)下必须提供 -s <AOI服务器地址>"; read -r -p "  请输入 AOI Server 地址(如 http://localhost/ ): " SERVER_ADDR; }
  case "$SERVER_ADDR" in
    http://*|https://*) : ;;
    *) die "服务器地址必须以 http:// 或 https:// 开头: $SERVER_ADDR" ;;
  esac
  ok "AOI Server: $SERVER_ADDR"

  if [ "$ENABLE_RANKER" -eq 1 ] && [ -z "$DB_ADDR" ]; then
    if [ "$YES" -eq 1 ]; then
      die "--ranker 模式必须提供 --db <MongoDB连接串>(一般复用 AOI 的 Mongo,如 mongodb://127.0.0.1:27017/aoi)"
    fi
    read -r -p "  请输入 MongoDB 连接串(ranker 需要,默认 mongodb://127.0.0.1:27017/aoi ): " DB_ADDR
    [ -z "$DB_ADDR" ] && DB_ADDR="mongodb://127.0.0.1:27017/aoi"
  fi
}

# -----------------------------------------------------------------------------
# 2. 自动安装缺失系统包
# -----------------------------------------------------------------------------
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

  local need_pkgs=()
  for i in "${MISSING[@]}"; do
    case "${i%%|*}" in
      curl|tar|unzip|find) need_pkgs+=("${i%%|*}") ;;
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

  echo
  info "── 重新检查依赖 ──────────────────────────"
  MISSING=()
  check_cmd curl "curl"
  check_cmd tar "tar"
  check_cmd unzip "unzip"
  check_cmd find "find"
  if [ "${#MISSING[@]}" -gt 0 ]; then
    die "仍有依赖未解决: $(printf '%s, ' "${MISSING[@]%%|*}")。请手动安装后重新运行。"
  fi
  echo
  ok "所有依赖已就绪"
}

# -----------------------------------------------------------------------------
# 3. 下载并安装 azukiiro 二进制
# -----------------------------------------------------------------------------
# 架构 → GitHub Release 友好文件名(与 assets/friendly-filenames.json 一致)
arch_friendly_name() {
  local m="$(uname -m)"
  case "$m" in
    x86_64|amd64)   echo "linux-64" ;;
    aarch64|arm64)  echo "linux-arm64-v8a" ;;
    armv7l|armv6l)  echo "linux-arm32-v7a" ;;
    riscv64)        echo "linux-riscv64" ;;
    loongarch64)    echo "linux-loong64" ;;
    *)              die "不支持的架构: $m(手动安装请从 GitHub Releases 选择对应 azukiiro-<name>.zip)" ;;
  esac
}

install_binary() {
  local bin_path="${INSTALL_DIR}/build/azukiiro"
  if [ -x "$bin_path" ] && [ "$FORCE" -eq 0 ]; then
    ok "二进制已存在: $bin_path($($bin_path info 2>/dev/null | head -1 || echo ''))"
    return 0
  fi

  local fname arch url zip_path dgst_url ver_desc
  arch="$(arch_friendly_name)"
  fname="azukiiro-${arch}.zip"
  url="${BASE_URL}/${fname}"
  dgst_url="${url}.dgst"

  [ "$REQ_VERSION" = "latest" ] && ver_desc="最新版" || ver_desc="v${REQ_VERSION}"
  log "下载 azukiiro(${ver_desc}, ${arch}): ${url}"
  [ "$FORCE" -eq 1 ] && log "(强制模式,覆盖已有二进制)"

  local tmp
  tmp="$(mktemp -d)"
  zip_path="${tmp}/${fname}"

  local retry ok2=0
  for retry in 1 2 3; do
    if curl -fsSL --connect-timeout 15 -m 300 "$url" -o "$zip_path" && [ -s "$zip_path" ]; then
      ok2=1
      break
    fi
    warn "下载失败(第 ${retry}/3 次),5 秒后重试..."
    sleep 5
  done
  [ "$ok2" -eq 1 ] || die "azukiiro 下载失败: $url。请检查网络,或设置 AZUKIIRO_BASE_URL 指向可用镜像。"

  # 校验 sha256(下载 .dgst,内容形如 "SHA256 = <hex>")
  if curl -fsSL --connect-timeout 10 -m 60 "$dgst_url" -o "$zip_path.dgst" 2>/dev/null; then
    local expect actual
    expect="$(grep -i '^SHA256' "$zip_path.dgst" | awk '{print $NF}' | tr -d '\r' || true)"
    actual="$(sha256sum "$zip_path" | awk '{print $1}')"
    if [ -n "$expect" ] && [ "$expect" = "$actual" ]; then
      ok "sha256 校验通过"
    else
      warn "sha256 校验失败(期望 ${expect:-不可用},实际 ${actual})——不校验继续,风险自负"
    fi
  else
    warn ".dgst 校验文件下载失败,跳过校验"
  fi

  log "解压安装到 ${INSTALL_DIR}/build/"
  sudo mkdir -p "${INSTALL_DIR}/build"
  mkdir -p "$tmp/x"
  unzip -oq "$zip_path" -d "$tmp/x" || { rm -rf "$tmp"; die "解压失败: $zip_path"; }
  if [ -f "$tmp/x/azukiiro" ]; then
    sudo install -m 0755 "$tmp/x/azukiiro" "$bin_path"
  else
    rm -rf "$tmp"
    die "压缩包结构异常(未找到 azukiiro 二进制)"
  fi
  rm -rf "$tmp"

  [ -x "$bin_path" ] || die "二进制安装失败: $bin_path"
  ok "二进制已安装: $bin_path"
}

# -----------------------------------------------------------------------------
# 4. 生成配置文件与系统用户
# -----------------------------------------------------------------------------
write_config() {
  [ "$FORCE" -eq 0 ] && [ "$REBIND" -eq 0 ] && [ -f "$CONFIG_FILE" ] && { warn "已存在 $CONFIG_FILE,跳过(如需重置加 -f,重新绑定加 --rebind)"; return 0; }

  sudo mkdir -p "$CONFIG_DIR"
  local content=""
  content="storagePath: ${STORAGE_PATH}
serverAddr: ${SERVER_ADDR}
"
  [ -n "$DB_ADDR" ] && content+="dbAddr: ${DB_ADDR}
"
  if [ "$ENABLE_INSTANCER" -eq 1 ]; then
    content+="instancer:
  docker:
    startTimeout: 30
    domainSuffix: .inst.localhost
    networkName: caddy
    hostInstancesPath: ${STORAGE_PATH}/instances
"
  fi

  # -f 重装时保留旧凭据(注册步骤仍会重新注册,见 do_register);
  # --rebind 重新绑定时清除旧凭据——新注册会生成全新的 runnerId/runnerKey
  if [ -f "$CONFIG_FILE" ] && [ "$REBIND" -eq 0 ]; then
    content+="$(grep -iE '^runner(id|key):' "$CONFIG_FILE" 2>/dev/null || true)"
  fi

  echo "$content" | sudo tee "$CONFIG_FILE" > /dev/null
  sudo chmod 644 "$CONFIG_FILE"
  ok "配置文件已生成: $CONFIG_FILE"
}

setup_user_and_dirs() {
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    log "创建系统用户 $SERVICE_USER..."
    sudo useradd --system --home-dir "$STORAGE_PATH" --shell /usr/sbin/nologin "$SERVICE_USER" 2>/dev/null \
      || sudo useradd --system --home-dir "$STORAGE_PATH" --shell /sbin/nologin "$SERVICE_USER"
    ok "系统用户 $SERVICE_USER 已创建"
  fi
  sudo mkdir -p "$STORAGE_PATH" "$INSTALL_DIR"
  sudo chown -R "$SERVICE_USER":"$SERVICE_USER" "$STORAGE_PATH"
  sudo chmod 750 "$STORAGE_PATH"
  ok "存储目录就绪: $STORAGE_PATH"
}

# -----------------------------------------------------------------------------
# 5. 注册到 AOI Server
# -----------------------------------------------------------------------------
do_register() {
  local bin_path="${INSTALL_DIR}/build/azukiiro"

  # 注意: viper 写回配置文件时会把键名小写化(runnerid:/runnerkey:),grep 需不区分大小写
  # --rebind 与 -f 都会跳过该检查,强制重新注册
  if [ "$REBIND" -eq 0 ] && [ "$FORCE" -eq 0 ] && grep -qiE '^runner(key|id):' "$CONFIG_FILE" 2>/dev/null; then
    ok "已注册过(runnerId/runnerKey 存在于 $CONFIG_FILE),跳过注册(--rebind 可强制重新绑定)"
    return 0
  fi

  if [ "$REBIND" -eq 1 ]; then
    warn "重新绑定模式: 将清除本地旧凭据并生成新的 runnerId/runnerKey"
    warn "AOI 前端 Runner 页面中残留的旧 runner 记录不会自动删除,请手动清理"
  fi

  if [ -z "$REG_TOKEN" ]; then
    if [ "$YES" -eq 1 ]; then
      die "全自动模式(-y)下必须提供 -t <registrationToken>"
    fi
    warn "需要一个 registrationToken:"
    warn "  1. 登录 AOI 前端,进入 组织 → Admin → Runner 页面"
    warn "  2. 点击『注册评测机』生成令牌(5 分钟有效),复制粘贴到下面"
    read -r -p "  请输入 registrationToken: " REG_TOKEN
  fi

  [ -z "$RUNNER_NAME" ] && RUNNER_NAME="$(hostname)"
  if [ "$ENABLE_RANKER" -eq 1 ] && ! echo ",$RUNNER_LABELS," | grep -qi ",ranker,"; then
    RUNNER_LABELS="${RUNNER_LABELS},ranker"
  fi
  if [ "$ENABLE_INSTANCER" -eq 1 ] && ! echo ",$RUNNER_LABELS," | grep -qi ",instance:"; then
    RUNNER_LABELS="${RUNNER_LABELS},instance:docker"
  fi

  log "注册 runner(${RUNNER_NAME}, labels: ${RUNNER_LABELS})..."
  sudo "$bin_path" register \
    --server "$SERVER_ADDR" \
    --token "$REG_TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$RUNNER_LABELS" \
    --force

  if ! grep -qiE '^runner(key|id):' "$CONFIG_FILE"; then
    fail "注册输出显示成功,但 $CONFIG_FILE 中未找到凭据(viper 写回键名小写)。文件当前内容:"
    cat "$CONFIG_FILE" 2>/dev/null || true
    die "请把上述文件内容反馈排查"
  fi
  ok "注册成功,凭据已写回 $CONFIG_FILE"
}

# -----------------------------------------------------------------------------
# 6. systemd 服务
# -----------------------------------------------------------------------------
install_systemd() {
  command -v systemctl >/dev/null 2>&1 || { warn "未检测到 systemd——跳过服务注册,请手动常驻运行: $INSTALL_DIR/build/azukiiro daemon"; return 0; }

  local unit="/etc/systemd/system/azukiiro@.service"
  if [ ! -f "$unit" ] || [ "$FORCE" -eq 1 ]; then
    sudo tee "$unit" > /dev/null <<EOF
[Unit]
Description=Azukiiro Judger
After=network.target syslog.target
Wants=network.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_USER}
Type=simple
ExecStart=${INSTALL_DIR}/build/azukiiro %i
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    ok "systemd 单元已安装: azukiiro@.service"
  else
    ok "systemd 单元已存在(如需覆盖加 -f)"
  fi

  # --rebind 后必须重启已运行的实例,否则 daemon 内存中仍是旧凭据
  sudo systemctl enable --now "azukiiro@daemon.service" >/dev/null 2>&1 \
    && ok "azukiiro@daemon 已启用并启动" \
    || warn "azukiiro@daemon 启动失败,请查看: sudo journalctl -u azukiiro@daemon -n 50"
  if [ "$REBIND" -eq 1 ] && sudo systemctl is-active --quiet azukiiro@daemon 2>/dev/null; then
    sudo systemctl restart azukiiro@daemon >/dev/null 2>&1 && ok "azukiiro@daemon 已重启(载入新凭据)"
  fi

  if [ "$ENABLE_RANKER" -eq 1 ]; then
    sudo systemctl enable --now "azukiiro@ranker.service" >/dev/null 2>&1 \
      && ok "azukiiro@ranker 已启用并启动" \
      || warn "azukiiro@ranker 启动失败,请查看: sudo journalctl -u azukiiro@ranker -n 50"
    if [ "$REBIND" -eq 1 ] && sudo systemctl is-active --quiet azukiiro@ranker 2>/dev/null; then
      sudo systemctl restart azukiiro@ranker >/dev/null 2>&1 && ok "azukiiro@ranker 已重启(载入新凭据)"
    fi
  fi

  if [ "$ENABLE_INSTANCER" -eq 1 ]; then
    sudo systemctl enable --now "azukiiro@instancer.service" >/dev/null 2>&1 \
      && ok "azukiiro@instancer 已启用并启动" \
      || warn "azukiiro@instancer 启动失败,请查看: sudo journalctl -u azukiiro@instancer -n 50"
    if [ "$REBIND" -eq 1 ] && sudo systemctl is-active --quiet azukiiro@instancer 2>/dev/null; then
      sudo systemctl restart azukiiro@instancer >/dev/null 2>&1 && ok "azukiiro@instancer 已重启(载入新凭据)"
    fi
  fi
}

# -----------------------------------------------------------------------------
# 7. 部署后检查
# -----------------------------------------------------------------------------
run_post_checks() {
  echo
  info "── 部署后自动检查 ────────────────────────"
  local pass=0 total=0

  total=$((total+1))
  if [ -x "${INSTALL_DIR}/build/azukiiro" ]; then
    ok "二进制: ${INSTALL_DIR}/build/azukiiro"
    pass=$((pass+1))
  else
    fail "二进制缺失: ${INSTALL_DIR}/build/azukiiro"
  fi

  total=$((total+1))
  if [ -f "$CONFIG_FILE" ] && grep -qiE '^serveraddr:' "$CONFIG_FILE"; then
    ok "配置: $CONFIG_FILE 已就绪"
    pass=$((pass+1))
  else
    fail "配置缺失: $CONFIG_FILE"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    total=$((total+1))
    if sudo systemctl is-active --quiet azukiiro@daemon 2>/dev/null; then
      ok "服务: azukiiro@daemon 运行中"
      pass=$((pass+1))
    else
      fail "服务: azukiiro@daemon 未运行"
    fi
    total=$((total+1))
    if sudo systemctl is-active --quiet azukiiro@ranker 2>/dev/null; then
      ok "服务: azukiiro@ranker 运行中"
      pass=$((pass+1))
    else
      warn "服务: azukiiro@ranker 未启用(未指定 --ranker 属正常)"
      total=$((total-1))
    fi
  fi

  echo
  if [ "$pass" -eq "$total" ]; then
    ok "全部 ${total} 项检查通过"
  else
    warn "${pass}/${total} 项通过,请根据失败项排查"
  fi
}

# -----------------------------------------------------------------------------
# 8. 总结与下一步
# -----------------------------------------------------------------------------
print_summary() {
  if [ "$ENABLE_UOJ" -eq 1 ]; then
    local uoj_hint="本脚本已安装 bwrap"
  else
    local uoj_hint="未安装(需 --with-uoj 或手动安装)"
  fi
  cat <<EOF

${C_GREEN}${C_BOLD}════════════════════════════════════════════════════════════${C_RESET}
${C_GREEN}${C_BOLD}  Azukiiro 评测机部署完成!                               ${C_RESET}
${C_GREEN}${C_BOLD}════════════════════════════════════════════════════════════${C_RESET}

${C_BOLD}接下来的 3 步:${C_RESET}

1) 在前端 AOI 刷新 组织 → Admin → Runner 页面,应能看到本机 runner(${RUNNER_NAME:-<主机名>})。
   若不在线,执行: sudo journalctl -u azukiiro@daemon -n 50 排查。
$([ "$REBIND" -eq 1 ] && echo "   注意: 本次为重新绑定,Runner 页里的旧 runner 记录请手动删除。")

2) 创建题目时,把题目数据 zip 里 problem.json 的 label 设为本机 runner 的标签之一
   (当前标签: ${RUNNER_LABELS})。runner 只能领取 label 匹配的提交!
   例: ${C_BOLD}problem.json: { "label": "${RUNNER_LABELS%%,*}", "judge": { "adapter": "dummy" } }${C_RESET}
   (dummy 适配器恒 AC,可先用它验证链路)

3) 提交一道题,前端应看到 state 流转 PENDING → QUEUED → RUNNING → COMPLETED,
   详情页出现评测结果(jobs/tests)。

${C_BOLD}适配器依赖备忘:${C_RESET}
   dummy / flag  —— 无额外依赖
   uoj(传统 OI)  —— 需 bwrap + /opt/uoj_judger(${uoj_hint})
   deno          —— 需 deno 可执行文件
   glue          —— 需 unsafe 编译标签的二进制
   vjudge        —— 需外网可达 vjudge.net
   instancer     —— 需 Docker + 外部 caddy 网络

${C_BOLD}常用管理命令:${C_RESET}
   sudo systemctl status azukiiro@daemon     # 查看评测守护进程状态
   sudo journalctl -u azukiiro@daemon -f     # 跟踪评测日志
   sudo systemctl restart azukiiro@daemon    # 重启
   ${INSTALL_DIR}/build/azukiiro info        # 查看版本/适配器/配置/runnerId
   ${INSTALL_DIR}/build/azukiiro judge --problem-config ... --problem-data ... --solution-data ...   # 本地调试评测

${C_BOLD}安全提醒:${C_RESET}
   • /etc/azukiiro/config.yaml 内含 runnerKey,请勿提交到 git/泄露
   • 评测机默认直接执行题目脚本(glue/deno),请只在可信组织内使用
   • 若要跑排行榜: 注册时加 -l ...ranker,且需 --db 指向 AOI 的 MongoDB

${C_YELLOW}提示: 重复运行本脚本是安全的(已存在的配置/二进制会跳过;加 -f 强制覆盖重装)。${C_RESET}
EOF
}

# -----------------------------------------------------------------------------
# 主流程
# -----------------------------------------------------------------------------
main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes) YES=1 ;;
      -f|--force) FORCE=1 ;;
      --rebind) REBIND=1 ;;
      -s|--server) SERVER_ADDR="$2"; shift ;;
      -t|--token) REG_TOKEN="$2"; shift ;;
      -n|--name) RUNNER_NAME="$2"; shift ;;
      -l|--labels) RUNNER_LABELS="$2"; shift ;;
      -d|--dir) INSTALL_DIR="$2"; shift ;;
      --ranker) ENABLE_RANKER=1 ;;
      --db) DB_ADDR="$2"; shift ;;
      --instancer) ENABLE_INSTANCER=1 ;;
      --with-uoj) ENABLE_UOJ=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数: $1(用 -h 查看帮助)" ;;
    esac
    shift
  done

  # 0) 权限检查
  if [ "$(id -u)" -eq 0 ]; then
    ok "权限: 以 root 运行"
  elif command -v sudo >/dev/null 2>&1; then
    ok "权限: 已检测到 sudo(需要时会自动以 sudo 执行系统操作)"
  else
    die "当前用户无 root 权限且系统中未安装 sudo,无法继续安装。请以 root 用户登录,或先安装 sudo 后重新运行: sudo bash $0 $*"
  fi

  cat <<EOF
${C_BOLD}┌──────────────────────────────────────────────────┐${C_RESET}
${C_BOLD}│   Azukiiro 评测机 · 一键部署脚本                │${C_RESET}
${C_BOLD}│   安装目录: ${INSTALL_DIR}${C_RESET}
${C_BOLD}│   AOI Server: ${SERVER_ADDR:-<未指定,将交互询问>}${C_RESET}
${C_BOLD}│   标签: ${RUNNER_LABELS}${C_RESET}
${C_BOLD}│   模式: $([ "$REBIND" -eq 1 ] && echo 重新绑定 --rebind || echo 全新安装)${C_RESET}
${C_BOLD}│   Ranker: $([ "$ENABLE_RANKER" -eq 1 ] && echo 启用 || echo 不启用)    Instancer: $([ "$ENABLE_INSTANCER" -eq 1 ] && echo 启用 || echo 不启用)${C_RESET}
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

  # 3) --with-uoj:安装 bwrap(uoj_judger 本体需自行部署到 /opt/uoj_judger)
  if [ "$ENABLE_UOJ" -eq 1 ]; then
    if command -v bwrap >/dev/null 2>&1; then
      ok "bwrap 已安装(uoj 沙箱)"
    else
      log "安装 bwrap(bubblewrap)..."
      case "$OS_ID" in
        ubuntu|debian|linuxmint) sudo apt-get update -qq && sudo apt-get install -y bubblewrap ;;
        centos|rhel|almalinux|rocky|fedora) sudo dnf install -y bubblewrap || sudo yum install -y bubblewrap ;;
        opensuse*|suse) sudo zypper --non-interactive install bubblewrap ;;
        *) warn "请手动安装 bubblewrap" ;;
      esac
      command -v bwrap >/dev/null 2>&1 && ok "bwrap 已安装" || warn "bwrap 安装失败,请手动安装"
    fi
    warn "uoj 适配器还需要 UOJ judger 本体(/opt/uoj_judger/main_judger),请从 UOJ-System 仓库构建部署。"
  fi

  # 4) 安装二进制 + 配置 + 注册
  echo
  info "── 安装二进制 ──────────────────────────────"
  install_binary

  echo
  info "── 生成配置 ────────────────────────────────"
  setup_user_and_dirs
  write_config

  echo
  info "── 注册到 AOI Server ───────────────────────"
  do_register

  # 5) 注册服务 + 检查
  echo
  info "── 注册系统服务 ────────────────────────────"
  install_systemd

  run_post_checks
  print_summary
}

main "$@"
