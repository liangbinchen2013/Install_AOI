#!/usr/bin/env bash
# =============================================================================
# AOI 评测机(UOJ Judger)部署脚本
# -----------------------------------------------------------------------------
# 背景:
#   azukiiro 的 uoj 适配器需要 /opt/uoj_judger/main_judger。
#   新旧两代 UOJ-System judger 格式不兼容(新版输出纯文本,azukiiro 期望 XML),
#   因此本脚本直接部署仓库中的 Python wrapper (main_judger_wrapper.py),
#   它负责编译→运行→比对→输出与 azukiiro uoj 适配器一致的 XML 结果。
#
# ⚠ 注意: 本脚本安装的是 Python wrapper,不是 UOJ-System 官方 C++ judger!
#
# 功能:
#   1. 安装编译依赖(g++,python3,bwrap)
#   2. 部署 Python wrapper 到 /opt/uoj_judger/main_judger
#   3. 设置 result/work 目录权限
#   4. 自检
#
# 用法:
#   bash setup_judge.sh                    交互模式
#   bash setup_judge.sh -y                 全自动
#   bash setup_judge.sh -f                 强制重新部署(默认幂等)
#
# 兼容系统: Ubuntu 20.04+/Debian 11+/CentOS 8+ (x86_64/aarch64)
# =============================================================================

set -Eeuo pipefail

INSTALL_DIR="${UOJ_INSTALL_DIR:-/opt/uoj_judger}"
# main_judger_wrapper.py 需与本脚本放在同一目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_SRC="${SCRIPT_DIR}/main_judger_wrapper.py"
YES=0
FORCE=0

if [ -t 1 ]; then
  C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
  C_CYAN=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_BOLD=''; C_RESET=''
fi

log()  { echo -e "${C_CYAN}[JUDGER]${C_RESET} $*"; }
info() { echo -e "  ${C_BOLD}$*${C_RESET}"; }
ok()   { echo -e "  ${C_GREEN}✔ $*${C_RESET}"; }
warn() { echo -e "  ${C_YELLOW}⚠ $*${C_RESET}"; }
fail() { echo -e "  ${C_RED}✘ $*${C_RESET}"; }
die()  { echo -e "${C_RED}[错误] $*${C_RESET}" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then sudo() { "$@"; }; fi

usage() {
  cat <<EOF
AOI 评测机(UOJ Judger)部署脚本

用法: bash $0 [选项]

选项:
  -y, --yes      全自动模式
  -f, --force    强制重新部署(默认已部署则跳过)
  -h, --help     显示本帮助

部署内容:
  /opt/uoj_judger/main_judger  ← Python wrapper(来自 main_judger_wrapper.py,输出 XML)
  /opt/uoj_judger/result/      ← 判题结果输出
  /opt/uoj_judger/work/        ← 判题工作目录

⚠ 注意: 安装的是 Python wrapper,不是 UOJ-System 官方 judger!

评测语言: C++(g++), Python3, Java, Pascal
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)    YES=1; shift ;;
    -f|--force)  FORCE=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "未知选项: $1"; usage; exit 1 ;;
  esac
done

echo
echo "┌──────────────────────────────────────────────────┐"
echo "│   AOI 评测机(UOJ Judger)· 部署脚本               │"
echo "│   安装目录: ${INSTALL_DIR}                         │"
echo "│   方案:     Python wrapper(兼容新旧 judger 格式)  │"
echo "└──────────────────────────────────────────────────┘"
echo
warn "注意: 本脚本安装的是 Python wrapper(main_judger_wrapper.py),"
warn "      不是 UOJ-System 官方 judger!"
echo

# -----------------------------------------------------------------------------
# 1. 系统检测
# -----------------------------------------------------------------------------
detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID}"
    OS_VER="${VERSION_ID:-unknown}"
    OS_PRETTY="${PRETTY_NAME:-${ID} ${VERSION_ID}}"
  elif [ -f /etc/redhat-release ]; then
    OS_ID="rhel"
    OS_VER="$(grep -oE '[0-9]+(\.[0-9]+)?' /etc/redhat-release | head -1)"
    OS_PRETTY="$(cat /etc/redhat-release)"
  else
    OS_ID="unknown"; OS_VER="unknown"; OS_PRETTY="unknown"
  fi
  ok "系统: ${OS_PRETTY} ($(uname -m))"
}
detect_os

# -----------------------------------------------------------------------------
# 2. 幂等检查
# -----------------------------------------------------------------------------
if [ -x "${INSTALL_DIR}/main_judger" ] && [ "$FORCE" -eq 0 ]; then
  ok "main_judger 已部署(${INSTALL_DIR}/main_judger)"
  if [ "$YES" -eq 0 ]; then
    echo -ne "  重新部署? [y/N] "; read -r ans
    case "$ans" in [Yy]*) FORCE=1 ;; *) info "跳过,保持现有安装"; exit 0 ;; esac
  else
    info "已存在,跳过(加 -f 强制重新部署)"; exit 0
  fi
fi

# -----------------------------------------------------------------------------
# 3. 安装依赖
# -----------------------------------------------------------------------------
MISSING=()
for cmd in g++ python3; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
command -v bwrap >/dev/null 2>&1 || MISSING+=("bwrap")

if [ ${#MISSING[@]} -gt 0 ]; then
  warn "需要安装 ${#MISSING[@]} 个依赖: ${MISSING[*]}"
  if [ "$YES" -eq 0 ]; then
    echo -ne "  继续? [Y/n] "; read -r ans
    case "$ans" in [Nn]*) die "取消安装" ;; esac
  fi
  log "安装依赖..."
  case "$OS_ID" in
    ubuntu|debian)
      sudo apt-get update -qq
      sudo apt-get install -y -qq g++ python3 bubblewrap 2>&1 | tail -3
      ;;
    centos|rhel|almalinux|rocky|fedora)
      local pm="dnf"; command -v dnf >/dev/null 2>&1 || pm="yum"
      sudo $pm install -y gcc-c++ python3 bubblewrap 2>&1 | tail -3
      ;;
    opensuse*|sles*)
      sudo zypper install -y gcc-c++ python3 bubblewrap 2>&1 | tail -3
      ;;
    *) die "不支持的系统: ${OS_ID},请手动安装 g++ python3 bubblewrap 后重试" ;;
  esac
  ok "依赖安装完成"
else
  ok "依赖已满足(g++, python3, bwrap)"
fi

# -----------------------------------------------------------------------------
# 4. 部署 Python wrapper(main_judger_wrapper.py)
# -----------------------------------------------------------------------------
log "部署 main_judger wrapper 到 ${INSTALL_DIR}..."
if [ ! -f "${WRAPPER_SRC}" ]; then
  die "未找到 ${WRAPPER_SRC} —— 请将 main_judger_wrapper.py 与本脚本放在同一目录"
fi

sudo rm -rf "${INSTALL_DIR}"
sudo mkdir -p "${INSTALL_DIR}/result" "${INSTALL_DIR}/work"

# 直接安装仓库中的 main_judger_wrapper.py(不再内嵌代码;
# 注意: 这是 Python wrapper,不是 UOJ-System 官方 C++ judger)
sudo cp "${WRAPPER_SRC}" "${INSTALL_DIR}/main_judger"
sudo chmod +x "${INSTALL_DIR}/main_judger"
# bwrap --unshare-all 下 azukiiro 用户(UID 映射后)需要写权限
sudo chmod 777 "${INSTALL_DIR}/result" "${INSTALL_DIR}/work"
ok "已部署 ${INSTALL_DIR}/main_judger"
ok "  ├── 来源: ${WRAPPER_SRC}"
ok "  ├── result/(判题结果输出,权限 777)"
ok "  └── work/(判题工作目录,权限 777)"
warn "注意: 安装的是 Python wrapper(main_judger_wrapper.py),"
warn "      不是 UOJ-System 官方 judger!"

# -----------------------------------------------------------------------------
# 5. 自检
# -----------------------------------------------------------------------------
log "自检..."
pass=0; total=0

total=$((total+1))
if [ -x "${INSTALL_DIR}/main_judger" ]; then
  ok "main_judger 已安装($(file "${INSTALL_DIR}/main_judger" | cut -d: -f2-))"
  pass=$((pass+1))
else
  fail "main_judger 缺失"
fi

total=$((total+1))
if [ -f "${WRAPPER_SRC}" ] && cmp -s "${WRAPPER_SRC}" "${INSTALL_DIR}/main_judger"; then
  ok "部署内容与 main_judger_wrapper.py 一致"
  pass=$((pass+1))
else
  fail "main_judger 与 main_judger_wrapper.py 不一致(需重跑脚本加 -f)"
fi

total=$((total+1))
if command -v g++ >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  ok "编译器可用: g++ $(g++ --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1), python3 $(python3 --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
  pass=$((pass+1))
else
  fail "编译器缺失"
fi

total=$((total+1))
if command -v bwrap >/dev/null 2>&1; then
  ok "bwrap $(bwrap --version 2>&1 | head -1)"
  pass=$((pass+1))
else
  fail "bwrap 缺失"
fi

echo
[ "$pass" -eq "$total" ] && ok "全部 ${total} 项自检通过" || warn "${pass}/${total} 项通过"

# -----------------------------------------------------------------------------
# 6. 输出配置信息
# -----------------------------------------------------------------------------
cpp_ver="未安装"
py3_ver="未安装"
command -v g++ >/dev/null 2>&1 && cpp_ver="$(g++ --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo '已安装')"
command -v python3 >/dev/null 2>&1 && py3_ver="$(python3 --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"

cat <<EOF

${C_GREEN}${C_BOLD}════════════════════════════════════════════════════════════${C_RESET}
${C_GREEN}${C_BOLD}  AOI 评测机 (Python wrapper) 部署完成!                  ${C_RESET}
${C_GREEN}${C_BOLD}════════════════════════════════════════════════════════════${C_RESET}

${C_BOLD}部署路径:${C_RESET}
   $(printf '%-15s %s' 'main_judger' "${INSTALL_DIR}/main_judger (Python wrapper)")
   $(printf '%-15s %s' 'result/' "${INSTALL_DIR}/result/")
   $(printf '%-15s %s' 'work/' "${INSTALL_DIR}/work/")

${C_BOLD}评测语言:${C_RESET}
   $(printf '%-22s %s' 'C++ / C++11 / C++14 / C++17' "${cpp_ver}")
   $(printf '%-22s %s' 'Python3' "${py3_ver}")
   $(printf '%-22s %s' 'Java' "$(command -v java >/dev/null 2>&1 && echo '已安装' || echo '未安装')")
   $(printf '%-22s %s' 'Pascal' "$(command -v fpc >/dev/null 2>&1 && echo '已安装' || echo '未安装')")

${C_BOLD}azukiiro 配置关联:${C_RESET}
   uoj 适配器路径: ${INSTALL_DIR}/main_judger
   runner 注册时 labels 包含 uoj。
   题目 problem.json 中: "label": "uoj", "judge": {"adapter": "uoj"}

${C_BOLD}与 AOI 前端关联(题目 problem.json):${C_RESET}
   "label": "uoj"
   "judge": {"adapter": "uoj", "config": {}}
   "submit": {"upload": true, "zipFolder": true}

${C_BOLD}常用命令:${C_RESET}
   file ${INSTALL_DIR}/main_judger
   bash setup_judge.sh -f                       # 修改 main_judger_wrapper.py 后重新部署
   sudo journalctl -u azukiiro@daemon -f       # 跟踪评测日志
   cat ${INSTALL_DIR}/result/wrapper.log        # wrapper 调试日志

${C_RED}${C_BOLD}⚠ 重要提醒:${C_RESET}
${C_RED}  本脚本安装的是 Python wrapper(main_judger_wrapper.py),${C_RESET}
${C_RED}  不是 UOJ-System 官方 C++ judger!${C_RESET}
${C_RED}  若需要官方 UOJ judger,请自行部署 uoj-judger 项目。${C_RESET}

${C_YELLOW}提示: wrapper 直接编译+运行+比对,输出 azukiiro 可解析的 XML 结果。${C_RESET}
${C_YELLOW}      重复运行本脚本幂等(已部署则跳过;-f 强制重部署)。${C_RESET}
EOF
