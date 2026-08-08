#!/usr/bin/env bash
# =============================================================================
# AOI 本地对象存储(OSS)部署脚本 · MinIO
# -----------------------------------------------------------------------------
# 背景(来自对 aoi 源码的分析,见 文档/数据与评测.md):
#   AOI 的数据(题目数据包/提交/评测详情/排行榜)全部存 S3 兼容对象存储。
#   服务端只负责用 AWS SDK 生成"预签名 URL"(SigV4),真正的上传/下载
#   由浏览器(前端上传)和评测机(azukiiro runner 下载数据)直连 OSS 完成。
#   因此本地 OSS 只要满足:
#     1. Endpoint 对浏览器与 azukiiro runner 可达(服务端容器不需要访问 OSS!)
#     2. 配置在 组织 Admin → Settings → OSS 设置(bucket/endpoint/accessKey/secretKey/region)
#     3. 浏览器跨源上传需要 MinIO 开启 CORS(本脚本自动配置)
#
# 功能:
#   1. 环境检查 —— Docker/端口/网络
#   2. 启动 MinIO 容器(API 9000 / 控制台 9001,数据持久化)
#   3. 生成强随机凭据并创建 bucket(默认 aoi)
#   4. 开启 CORS + 写入/读取自检
#   5. 输出前端 OSS 配置表单所需的全部字段
#
# 用法:
#   bash setup_OSS.sh                    交互模式
#   bash setup_OSS.sh -y                 全自动
#   bash setup_OSS.sh -p 19000           自定义 API 端口(默认 9000)
#   bash setup_OSS.sh -H 192.168.1.5     局域网访问时指定可达地址(默认 localhost)
#   bash setup_OSS.sh -f                 重新生成凭据/重建容器
#
# 环境变量:
#   OSS_MINIO_IMAGE    MinIO 镜像(默认 minio/minio:latest,国内可指加速器前缀)
#   OSS_MC_IMAGE       mc 客户端镜像(默认 minio/mc:latest)
#   OSS_DATA_DIR       数据目录(默认 /opt/aoi-oss)
#
# 兼容系统: Ubuntu/Debian/CentOS/RHEL/Alma/Rocky/openSUSE/Fedora (x86_64/aarch64)
# Windows 用户请使用 WSL2 或 Linux 服务器运行本脚本。
# =============================================================================

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# 基础配置
# -----------------------------------------------------------------------------
PORT="${OSS_PORT:-9000}"
CONSOLE_PORT="${OSS_CONSOLE_PORT:-9001}"
HOST="${OSS_HOST:-localhost}"
BUCKET="${OSS_BUCKET:-aoi}"
REGION="${OSS_REGION:-us-east-1}"
DATA_DIR="${OSS_DATA_DIR:-/opt/aoi-oss}"
CREDS_FILE="${DATA_DIR}/.oss-env"
# MinIO 2025+ 官方镜像内置 ENV: MINIO_ROOT_USER_FILE=access_key / MINIO_ROOT_PASSWORD_FILE=secret_key
# (相对容器工作目录 / 的文件名)。镜像据此读取 root 凭据,文件缺失时回退默认 minioadmin,
# 导致凭据失效。因此把凭据写入宿主文件并挂载到容器 /access_key、/secret_key。
MINIO_KEY_FILE="${DATA_DIR}/access_key"
MINIO_SECRET_FILE="${DATA_DIR}/secret_key"
# mc 客户端配置目录(挂载进容器持久化,alias 跨命令生效)
MC_ALIAS_DIR="${DATA_DIR}/.mc"
CONTAINER="aoi-minio"
MINIO_IMAGE="${OSS_MINIO_IMAGE:-minio/minio:latest}"
MC_IMAGE="${OSS_MC_IMAGE:-minio/mc:latest}"

YES=0
FORCE=0

# 颜色输出(非终端自动禁用)
if [ -t 1 ]; then
  C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
  C_CYAN=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_BOLD=''; C_RESET=''
fi

log()  { echo -e "${C_CYAN}[OSS]${C_RESET} $*"; }
info() { echo -e "  ${C_BOLD}$*${C_RESET}"; }
ok()   { echo -e "  ${C_GREEN}✔ $*${C_RESET}"; }
warn() { echo -e "  ${C_YELLOW}⚠ $*${C_RESET}"; }
fail() { echo -e "  ${C_RED}✘ $*${C_RESET}"; }
die()  { echo -e "${C_RED}[错误] $*${C_RESET}" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then
  sudo() { "$@"; }
fi

usage() {
  cat <<EOF
AOI 本地对象存储(OSS,MinIO)部署脚本

用法: bash $0 [选项]

选项:
  -y, --yes            全自动模式:不询问任何问题
  -p, --port <端口>    OSS API 端口(默认 9000)
      --console <端口>  管理控制台端口(默认 9001)
  -H, --host <地址>    浏览器/评测机访问 OSS 用的地址(默认 localhost)
                       局域网使用请填本机局域网 IP,如 192.168.1.5
  -b, --bucket <名称>  bucket 名称(默认 aoi,与前端表单预填一致)
  -d, --dir <目录>     数据持久化目录(默认 $DATA_DIR)
  -f, --force          强制重建容器并重新生成凭据(默认幂等:已部署则跳过)
  -h, --help           显示本帮助

示例:
  bash $0 -y                              # 本机使用,Endpoint = http://localhost:9000
  bash $0 -y -H 192.168.1.5               # 局域网其他设备也要访问
  bash $0 -p 19000 --console 19001        # 端口被占时换端口

注意:
  安装 Docker / 启动容器需要 root 权限,非 root 请用 sudo 运行。
  部署完成后,把脚本输出的字段填入 AOI 前端:
    组织 Admin → Settings → OSS 设置
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
OS_ID=""; OS_PRETTY=""

detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-}"; OS_PRETTY="${PRETTY_NAME:-}"
  fi

  case "$(uname -s)" in
    Linux) : ;;
    MINGW*|MSYS*|CYGWIN*|Darwin)
      die "检测到 $(uname -s):请改用 WSL2 或 Linux 服务器运行本脚本。"
      ;;
    *) die "不支持的系统: $(uname -s)" ;;
  esac
  [ -n "$OS_PRETTY" ] && ok "系统: $OS_PRETTY ($(uname -m))"
}

MISSING=()

check_docker() {
  if command -v docker >/dev/null 2>&1; then
    local ver
    ver="$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
    ok "Docker 已安装 ($ver)"
    if ! docker info >/dev/null 2>&1; then
      warn "docker daemon 不可达(未运行或当前用户无权限),尝试启动..."
      # 已有 docker 时只尝试启动 daemon,绝不重装(常见于 WSL:daemon 在跑但用户不在 docker 组)
      sudo systemctl start docker >/dev/null 2>&1 \
        || sudo service docker start >/dev/null 2>&1 || true
      local tries=0
      until docker info >/dev/null 2>&1 || [ "$tries" -ge 15 ]; do sleep 1; tries=$((tries+1)); done
      if docker info >/dev/null 2>&1; then
        ok "docker daemon 已启动"
      else
        warn "仍无法访问 docker daemon——非 root 用户通常需要: sudo usermod -aG docker \$USER 后重新登录,"
        warn "或用 root 运行本脚本(如 WSL: wsl -u root -- bash $0)"
        MISSING+=("docker-running|start docker daemon")
      fi
    fi
  else
    fail "Docker 缺失(本脚本将用官方脚本自动安装)"
    MISSING+=("docker|get.docker.com 官方脚本")
  fi
}

check_port() { # $1=端口  $2=服务名
  # 本脚本已部署的 MinIO 容器自身映射该端口时不算冲突
  if docker inspect "$CONTAINER" >/dev/null 2>&1 \
     && docker inspect -f '{{range $k, $v := .NetworkSettings.Ports}}{{$k}} {{end}}' "$CONTAINER" 2>/dev/null \
        | grep -q "${1}/tcp"; then
    ok "端口 ${1}($2)由本脚本的 MinIO 容器占用(正常)"
    return 0
  fi
  local used=0
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}$" && used=1
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}$" && used=1
  fi
  if [ "$used" -eq 1 ]; then
    warn "端口 ${1}($2)已被占用——可用 -p/--console 换端口,或先停掉占用进程"
  else
    ok "端口 ${1}($2)可用"
  fi
}

check_network() {
  # 提取镜像仓库 host: 含 . 或 : 的第一段是域名;否则是 Docker Hub 官方镜像(如 minio/minio)
  local img_host="${MINIO_IMAGE%%/*}"
  case "$img_host" in
    *.*|*:*|localhost) : ;;
    *) img_host="registry-1.docker.io" ;;
  esac
  if curl -fsSI --connect-timeout 5 -m 8 "https://${img_host}" >/dev/null 2>&1; then
    ok "网络可达: ${img_host}(拉取 MinIO 镜像)"
  else
    warn "无法访问 ${img_host}——拉取镜像将失败。国内环境可用:"
    warn "  OSS_MINIO_IMAGE=docker.m.daocloud.io/minio/minio:latest OSS_MC_IMAGE=docker.m.daocloud.io/minio/mc:latest bash $0"
  fi
}

run_checks() {
  info "── 环境检查 ──────────────────────────────"
  check_docker
  check_port "$PORT" "MinIO API"
  check_port "$CONSOLE_PORT" "MinIO 控制台"
  check_network
}

# -----------------------------------------------------------------------------
# 2. 自动安装 Docker(缺失时)
# -----------------------------------------------------------------------------
install_docker() {
  [ "${#MISSING[@]}" -eq 0 ] && return 0

  # 先处理"daemon 未运行"类:只启动,不重装
  local i still=()
  for i in "${MISSING[@]}"; do
    if [ "${i%%|*}" = "docker-running" ]; then
      log "再次尝试启动 docker daemon..."
      sudo systemctl start docker >/dev/null 2>&1 \
        || sudo service docker start >/dev/null 2>&1 || true
      local tries=0
      until docker info >/dev/null 2>&1 || [ "$tries" -ge 15 ]; do sleep 1; tries=$((tries+1)); done
      if docker info >/dev/null 2>&1; then
        ok "docker daemon 已启动"
      else
        warn "docker daemon 仍无法访问——请用 root 运行本脚本,或把当前用户加入 docker 组后重新登录"
        still+=("$i")
      fi
    else
      still+=("$i")
    fi
  done
  MISSING=("${still[@]}")
  [ "${#MISSING[@]}" -eq 0 ] && return 0

  echo
  info "以下依赖缺失,需要自动安装:"
  local i
  for i in "${MISSING[@]}"; do
    info "  - ${i%%|*}: ${i#*|}"
  done
  echo
  if ! confirm "是否现在自动安装 Docker?"; then
    die "已取消。请手动安装 Docker 后重新运行本脚本。"
  fi

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
  rm -f /tmp/get-docker.sh
  if [ "$dl_ok" -ne 1 ]; then
    case "$OS_ID" in
      ubuntu|debian|linuxmint)
        sudo apt-get update -qq && sudo apt-get install -y docker.io || die "Docker 安装失败,请手动安装后重跑本脚本"
        ;;
      *)
        die "Docker 安装失败(官方脚本不可达且当前发行版无自动 fallback),请手动安装 Docker 后重跑本脚本"
        ;;
    esac
  fi

  log "启动 Docker 服务..."
  sudo systemctl enable --now docker >/dev/null 2>&1 || sudo service docker start >/dev/null 2>&1 || true
  local tries=0
  until sudo docker info >/dev/null 2>&1 || [ "$tries" -ge 15 ]; do sleep 1; tries=$((tries+1)); done

  echo
  sudo docker info >/dev/null 2>&1 || die "Docker 仍未就绪"
  ok "Docker 已就绪"
}

# -----------------------------------------------------------------------------
# 3. 凭据生成
# -----------------------------------------------------------------------------
load_or_gen_creds() {
  if [ ! -f "$CREDS_FILE" ] || [ "$FORCE" -eq 1 ] \
     || ! . "$CREDS_FILE" || [ -z "${ACCESS_KEY:-}" ] || [ -z "${SECRET_KEY:-}" ]; then
    # MinIO 要求: 用户名 ≥3 字符且仅字母数字;密码 ≥8 字符
    ACCESS_KEY="aoi$(head -c 12 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 12)"
    SECRET_KEY="$(head -c 36 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
    sudo mkdir -p "$DATA_DIR"
    printf 'ACCESS_KEY=%s\nSECRET_KEY=%s\n' "$ACCESS_KEY" "$SECRET_KEY" \
      | sudo tee "$CREDS_FILE" > /dev/null
    sudo chmod 600 "$CREDS_FILE"
    ok "已生成强随机凭据并保存到 $CREDS_FILE(权限 600)"
  else
    ok "复用已有凭据($CREDS_FILE)"
  fi

  # 把凭据写入挂载文件(见 MINIO_KEY_FILE 注释:镜像内置 FILE 变量指向 /access_key、/secret_key)
  printf '%s' "$ACCESS_KEY" | sudo tee "$MINIO_KEY_FILE" > /dev/null
  printf '%s' "$SECRET_KEY" | sudo tee "$MINIO_SECRET_FILE" > /dev/null
  sudo chmod 600 "$MINIO_KEY_FILE" "$MINIO_SECRET_FILE"
}

# -----------------------------------------------------------------------------
# 4. 启动 MinIO
# -----------------------------------------------------------------------------
wait_minio() {
  log "等待 MinIO 就绪(最多 60 秒)..."
  local i
  for i in $(seq 1 30); do
    if curl -fsS --connect-timeout 3 -m 5 "http://localhost:${PORT}/minio/health/live" >/dev/null 2>&1; then
      echo
      ok "MinIO 已就绪(耗时约 $((i * 2)) 秒)"
      return 0
    fi
    sleep 2
  done
  echo
  warn "MinIO 未就绪,请查看: docker logs $CONTAINER"
  return 1
}

start_minio() {
  if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    if [ "$FORCE" -eq 1 ]; then
      log "强制重建容器 $CONTAINER..."
      if [ -d "${DATA_DIR}/data" ]; then
        warn "清空数据卷 ${DATA_DIR}/data(--force 会重新生成凭据,旧数据盘存有旧凭据必须一并清除)"
        sudo rm -rf "${DATA_DIR}/data"
      fi
      sudo docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    elif docker inspect -f '{{range .Mounts}}{{println .Destination}}{{end}}' "$CONTAINER" 2>/dev/null \
         | grep -qx '/access_key'; then
      # 当前版本脚本创建的容器(带凭据文件挂载):复用或启动
      ok "容器 $CONTAINER 已存在($(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null))"
      if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
        warn "容器存在但未运行,尝试启动..."
        sudo docker start "$CONTAINER" >/dev/null 2>&1 \
          || { sudo docker rm -f "$CONTAINER" >/dev/null 2>&1; start_minio; }
      fi
      return 0
    else
      warn "容器 $CONTAINER 由旧版本脚本创建(缺少凭据文件挂载,MinIO 将回退默认凭据),重建..."
      sudo docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    fi
  fi

  log "启动 MinIO 容器(${MINIO_IMAGE})..."
  sudo docker run -d --name "$CONTAINER" --restart unless-stopped \
    -p "${PORT}:9000" -p "${CONSOLE_PORT}:9001" \
    -e "MINIO_ROOT_USER=${ACCESS_KEY}" \
    -e "MINIO_ROOT_PASSWORD=${SECRET_KEY}" \
    -e "MINIO_API_CORS_ALLOW_ORIGIN=*" \
    -v "${DATA_DIR}/data:/data" \
    -v "${MINIO_KEY_FILE}:/access_key:ro" \
    -v "${MINIO_SECRET_FILE}:/secret_key:ro" \
    "$MINIO_IMAGE" server /data --console-address ":9001" \
    || die "MinIO 容器启动失败,请查看: sudo docker logs $CONTAINER"
  wait_minio
}

# -----------------------------------------------------------------------------
# 5. 创建 bucket / CORS / 自检
# -----------------------------------------------------------------------------
# mc 在一次性容器里执行(--rm);--network host 使容器内 localhost 指向宿主机;
# 挂载 mc 配置目录,使 alias set 跨命令持久(否则每次 --rm 后 alias 丢失,后续命令报 Access Denied);
# -i 保持 stdin 打开(mc pipe 从 stdin 上传,不带 -i 时 stdin 为 0 字节)
mc() { sudo docker run -i --rm --network host -v "${MC_ALIAS_DIR}:/root/.mc" "$MC_IMAGE" "$@"; }

setup_bucket() {
  log "配置 bucket(${BUCKET})..."
  mc alias set local "http://localhost:${PORT}" "$ACCESS_KEY" "$SECRET_KEY" >/dev/null 2>&1 \
    || die "mc 无法连接 MinIO(凭据或网络问题),请检查: sudo docker logs $CONTAINER"

  if mc ls "local/${BUCKET}" >/dev/null 2>&1; then
    ok "bucket ${BUCKET} 已存在"
  else
    mc mb "local/${BUCKET}" >/dev/null 2>&1 && ok "bucket ${BUCKET} 已创建" \
      || die "bucket 创建失败: mc mb local/${BUCKET}"
  fi

  # CORS 由容器环境变量 MINIO_API_CORS_ALLOW_ORIGIN=* 开启:MinIO 不支持 S3 PutBucketCors API,
  # mc cors set 对 MinIO 必然返回 NotImplemented,无需尝试
  ok "CORS 已开启(容器环境变量 MINIO_API_CORS_ALLOW_ORIGIN=* 允许任意来源跨源上传)"
}

self_test() {
  log "写入/读取自检..."
  local mark="aoi-oss-setup-ok-$(date +%s)"
  if echo "$mark" | mc pipe "local/${BUCKET}/.setup-check" >/dev/null 2>&1 \
    && [ "$(mc cat "local/${BUCKET}/.setup-check" 2>/dev/null)" = "$mark" ]; then
    mc rm "local/${BUCKET}/.setup-check" >/dev/null 2>&1 || true
    ok "写入/读取自检通过(上传下载链路正常)"
  else
    warn "自检失败——请确认端口 ${PORT} 对外可达,或检查 docker logs $CONTAINER"
  fi
}

# -----------------------------------------------------------------------------
# 6. 部署后检查与输出
# -----------------------------------------------------------------------------
run_post_checks() {
  echo
  info "── 部署后自动检查 ────────────────────────"
  local pass=0 total=0

  total=$((total+1))
  if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = "true" ]; then
    ok "容器状态: $CONTAINER 运行中"
    pass=$((pass+1))
  else
    fail "容器未运行: $CONTAINER"
  fi

  total=$((total+1))
  if curl -fsS --connect-timeout 5 -m 8 "http://localhost:${PORT}/minio/health/live" >/dev/null 2>&1; then
    ok "健康检查 /minio/health/live 通过"
    pass=$((pass+1))
  else
    fail "MinIO 健康检查失败"
  fi

  echo
  [ "$pass" -eq "$total" ] && ok "全部 ${total} 项检查通过" || warn "${pass}/${total} 项通过"
}

print_summary() {
  local endpoint="http://${HOST}:${PORT}"

  cat <<EOF

${C_GREEN}${C_BOLD}════════════════════════════════════════════════════════════${C_RESET}
${C_GREEN}${C_BOLD}  本地 OSS(MinIO)部署完成!                                ${C_RESET}
${C_GREEN}${C_BOLD}════════════════════════════════════════════════════════════${C_RESET}

${C_BOLD}把以下字段填入 AOI 前端:${C_RESET}
   组织 → Admin → Settings → OSS 设置 → 启用 OSS

   $(printf '%-10s %-42s %s' 'Endpoint' "${endpoint}" 'MinIO 服务地址,浏览器/评测机均需可达')
   $(printf '%-10s %-42s %s' 'Bucket' "${BUCKET}" '启用 OSS 时前端自动预填 aoi,保持即可')
   $(printf '%-10s %-42s %s' 'Region' "${REGION}" '本地 MinIO 无实际区域概念,保持 us-east-1')
   $(printf '%-10s %-42s %s' 'AccessKey' "${ACCESS_KEY}" '脚本生成的访问密钥(见凭据文件)')
   $(printf '%-10s %-42s %s' 'SecretKey' "${SECRET_KEY}" '与 AccessKey 配对;留空=保持不变')
   $(printf '%-10s %-42s %s' 'PathStyle' '☑ 勾选' '设置了 Endpoint 后前端默认自动启用')

${C_BOLD}关键约束:${C_RESET}
   • Endpoint 必须对【浏览器】和【azukiiro 评测机】同时可达
     - 本机使用: http://localhost:${PORT} ✓
     - 局域网使用: 用 -H <本机局域网IP> 重跑本脚本,如 http://192.168.1.5:${PORT}
       (AOI 服务器容器不需要访问 OSS——它只生成预签名 URL)
   • 若浏览器访问 OSS 报 CORS 错误,检查容器环境变量 MINIO_API_CORS_ALLOW_ORIGIN
   • 配置保存后,上传题目数据、提交一道题验证全链路

${C_BOLD}管理控制台:${C_RESET} http://${HOST}:${CONSOLE_PORT}(凭据同上,网页图形化管理)
${C_BOLD}数据目录:${C_RESET}   ${DATA_DIR}/data(备份请备份此目录)
${C_BOLD}凭据文件:${C_RESET}   ${CREDS_FILE}(权限 600,勿泄露)

${C_BOLD}常用命令:${C_RESET}
   sudo docker logs -f $CONTAINER             # 跟踪日志
   sudo docker restart $CONTAINER             # 重启
   sudo docker rm -f $CONTAINER               # 删除容器(数据保留在 ${DATA_DIR}/data)
   sudo docker run --rm --network host -v ${DATA_DIR}/.mc:/root/.mc ${MC_IMAGE} alias set local http://localhost:${PORT} ${ACCESS_KEY} ${SECRET_KEY}
   sudo docker run --rm --network host -v ${DATA_DIR}/.mc:/root/.mc ${MC_IMAGE} ls local/${BUCKET}   # 列对象
   # (alias 配置保存在 ${DATA_DIR}/.mc,两个命令都要带同样的 -v 挂载)

${C_YELLOW}提示: 重复运行本脚本是安全的(已部署则跳过;加 -f 强制重建并重新生成凭据——注意重建后需同步更新前端配置)。${C_RESET}
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
      -p|--port) PORT="$2"; shift ;;
      --console) CONSOLE_PORT="$2"; shift ;;
      -H|--host) HOST="$2"; shift ;;
      -b|--bucket) BUCKET="$2"; shift ;;
      -d|--dir) DATA_DIR="$2"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数: $1(用 -h 查看帮助)" ;;
    esac
    shift
  done

  if [ "$(id -u)" -eq 0 ]; then
    ok "权限: 以 root 运行"
  elif command -v sudo >/dev/null 2>&1; then
    ok "权限: 已检测到 sudo(需要时会自动以 sudo 执行系统操作)"
  else
    die "当前用户无 root 权限且系统中未安装 sudo,无法继续安装。请以 root 用户登录,或先安装 sudo 后重新运行: sudo bash $0 $*"
  fi

  cat <<EOF
${C_BOLD}┌──────────────────────────────────────────────────┐${C_RESET}
${C_BOLD}│   AOI 本地对象存储(MinIO)· 部署脚本            │${C_RESET}
${C_BOLD}│   Endpoint: http://${HOST}:${PORT}${C_RESET}
${C_BOLD}│   Bucket: ${BUCKET}    Region: ${REGION}${C_RESET}
${C_BOLD}│   控制台: http://${HOST}:${CONSOLE_PORT}${C_RESET}
${C_BOLD}│   数据目录: ${DATA_DIR}${C_RESET}
${C_BOLD}└──────────────────────────────────────────────────┘${C_RESET}
EOF

  detect_os
  run_checks
  install_docker

  echo
  info "── 部署 MinIO ──────────────────────────────"
  load_or_gen_creds
  start_minio
  setup_bucket
  self_test

  run_post_checks
  print_summary
}

main "$@"
