#!/usr/bin/env bash
# =============================================================================
# AOI 评测机(UOJ Judger)部署脚本
# -----------------------------------------------------------------------------
# 背景:
#   azukiiro 的 uoj 适配器需要 /opt/uoj_judger/main_judger。
#   新旧两代 UOJ-System judger 格式不兼容(新版输出纯文本,azukiiro 期望 XML),
#   因此本脚本部署一个 Python wrapper,直接做编译→运行→比对→输出 XML。
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
  /opt/uoj_judger/main_judger  ← Python wrapper(编译+运行+比对,输出 XML)
  /opt/uoj_judger/result/      ← 判题结果输出
  /opt/uoj_judger/work/        ← 判题工作目录

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
# 4. 部署 Python wrapper
# -----------------------------------------------------------------------------
log "部署 main_judger wrapper 到 ${INSTALL_DIR}..."
sudo rm -rf "${INSTALL_DIR}"
sudo mkdir -p "${INSTALL_DIR}/result" "${INSTALL_DIR}/work"

# 嵌入的 Python wrapper(见本脚本末尾 WRAPPER_EOF 标记)
sudo tee "${INSTALL_DIR}/main_judger" > /dev/null <<'WRAPPER_EOF'
#!/usr/bin/python3
"""
AOI / azukiiro UOJ adapter 兼容层 — 编译+运行+比对+输出 XML
"""
import os, sys, shutil, subprocess, traceback, xml.etree.ElementTree as ET
from pathlib import Path

LOG_FILE = '/opt/uoj_judger/result/wrapper.log'
def log(msg):
    try:
        with open(LOG_FILE, 'a') as f: f.write(f'{msg}\n')
    except: pass

def parse_conf(path):
    conf = {}
    if os.path.exists(path):
        with open(path, encoding='utf-8', errors='replace') as f:
            for line in f:
                line = line.strip()
                if not line or ' ' not in line: continue
                key, value = line.split(' ', 1)
                conf[key.strip()] = value.strip()
    return conf

def error_result(status, message):
    root = ET.Element('result')
    ET.SubElement(root, 'score').text = '0'
    ET.SubElement(root, 'time').text = '0'
    ET.SubElement(root, 'memory').text = '0'
    ET.SubElement(root, 'error').text = status
    details = ET.SubElement(root, 'details')
    ET.SubElement(details, 'error').text = message
    return ET.tostring(root, encoding='unicode')

def compile_solution(sol_dir, lang, work_dir):
    sources = []
    for ext in ['.cpp', '.cc', '.cxx', '.c', '.pas', '.py', '.java']:
        sources.extend(Path(sol_dir).glob(f'*{ext}'))
    if not sources: return False, "No source file found"
    src = sources[0]
    exec_path = os.path.join(work_dir, 'program')
    lang_lower = lang.lower()
    if lang_lower in ('c++', 'c++11', 'c++14', 'c++17'):
        cmd = ['g++', '-std=c++17', '-O2', '-o', exec_path, str(src)]
    elif lang_lower.startswith('python'):
        shutil.copy(str(src), exec_path + '.py')
        return True, exec_path + '.py'
    elif lang_lower == 'java':
        cmd = ['javac', '-d', work_dir, str(src)]
    elif lang_lower == 'pascal':
        cmd = ['fpc', '-O2', '-o' + exec_path, str(src)]
    else:
        return False, f"Unsupported language: {lang}"
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30, cwd=work_dir)
        if result.returncode != 0:
            return False, f"Compile Error:\n{result.stderr[:500]}\n{result.stdout[:500]}"
        return True, exec_path
    except subprocess.TimeoutExpired:
        return False, "Compile timeout"
    except FileNotFoundError:
        return False, f"Compiler not found: {cmd[0]}"

def run_test(exec_path, lang, input_file, work_dir, time_limit, mem_limit):
    try:
        with open(input_file, 'r') as f: input_data = f.read()
    except FileNotFoundError:
        return False, f"Input file not found: {input_file}", 0, 0
    lang_lower = lang.lower()
    if lang_lower.startswith('python'):
        cmd = ['python3', exec_path]
    elif lang_lower == 'java':
        cmd = ['java', '-cp', work_dir, os.path.splitext(os.path.basename(exec_path))[0]]
    else:
        cmd = [exec_path]
    try:
        result = subprocess.run(cmd, input=input_data, capture_output=True,
                                text=True, timeout=time_limit, cwd=work_dir)
        if result.returncode != 0:
            return False, f"Runtime Error (exit {result.returncode})\n{result.stderr[:300]}", 0, 0
        return True, result.stdout, 0, 0
    except subprocess.TimeoutExpired:
        return False, "Time Limit Exceeded", time_limit * 1000, 0
    except Exception as e:
        return False, f"Runtime Error: {e}", 0, 0

def compare_output(actual, expected_file, checker='ncmp'):
    try:
        with open(expected_file, 'r') as f: expected = f.read()
    except FileNotFoundError:
        return False, f"Expected output not found: {expected_file}"
    if checker in ('ncmp', 'acmp', 'wcmp'):
        def normalize(s):
            return '\n'.join(line.rstrip() for line in s.rstrip('\n').split('\n'))
        return normalize(actual) == normalize(expected), "Output mismatch"
    else:
        return actual.strip() == expected.strip(), "Output mismatch"

def main():
    if len(sys.argv) < 3:
        print("Usage: main_judger <solution_dir> <problem_dir>", file=sys.stderr)
        sys.exit(1)
    sol_dir = sys.argv[1]
    prob_dir = sys.argv[2]
    result_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'result')
    work_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'work')
    log(f'sol_dir={sol_dir} prob_dir={prob_dir}')
    log(f'sol exists={os.path.isdir(sol_dir)} prob exists={os.path.isdir(prob_dir)}')
    if os.path.isdir(sol_dir):
        log(f'sol contents: {os.listdir(sol_dir)[:20]}')
    os.makedirs(result_dir, exist_ok=True)
    os.makedirs(work_dir, exist_ok=True)

    prob_conf = parse_conf(os.path.join(prob_dir, 'problem.conf'))
    sub_conf = parse_conf(os.path.join(sol_dir, 'submission.conf'))
    lang = sub_conf.get('answer_language', 'C++14')

    ok, msg = compile_solution(sol_dir, lang, work_dir)
    if not ok:
        xml = error_result('Compile Error', msg)
        with open(os.path.join(result_dir, 'result.txt'), 'w') as f: f.write(xml)
        print(xml)
        return

    exec_path = msg
    input_suf = prob_conf.get('input_suf', 'in')
    output_suf = prob_conf.get('output_suf', 'out')
    time_limit = max(1, int(prob_conf.get('time_limit', '1')))

    tests = sorted(Path(prob_dir).glob(f'*.{input_suf}'))
    if not tests: tests = sorted(Path(prob_dir).glob('*.in'))

    root = ET.Element('result')
    total_score = 0
    final_status = 'Accepted'
    details = ET.SubElement(root, 'details')
    subtask = ET.SubElement(details, 'subtask', {
        'num': '1', 'score': prob_conf.get('subtask_score_1', '100'),
        'info': 'Accepted', 'time': '0', 'memory': '0', 'type': 'sum'
    })
    subtask_score = float(prob_conf.get('subtask_score_1', '100'))

    for i, test_in in enumerate(tests, 1):
        test_num = int(''.join(c for c in test_in.stem if c.isdigit()) or i)
        test_out = test_in.with_suffix(f'.{output_suf}')
        if not test_out.exists(): test_out = test_in.with_suffix('.out')

        ok, output, t, m = run_test(exec_path, lang, str(test_in), work_dir, time_limit, 0)
        test_elem = ET.SubElement(subtask, 'test', {
            'num': str(test_num), 'score': '0', 'info': 'Accepted',
            'time': str(t), 'memory': str(m)
        })
        ET.SubElement(test_elem, 'in').text = Path(test_in).read_text(encoding='utf-8', errors='replace')[:500]
        ET.SubElement(test_elem, 'out').text = output[:500] if ok else output
        ET.SubElement(test_elem, 'res').text = ''

        if not ok:
            if 'Time' in output:
                test_elem.set('info', 'Time Limit Exceeded')
                final_status = 'Time Limit Exceeded'
            else:
                test_elem.set('info', 'Runtime Error')
                if final_status == 'Accepted': final_status = 'Runtime Error'
            continue
        match, _ = compare_output(output, str(test_out))
        if match:
            test_elem.set('score', str(subtask_score / len(tests)))
            total_score += subtask_score / len(tests)
        else:
            test_elem.set('info', 'Wrong Answer')
            if final_status == 'Accepted': final_status = 'Wrong Answer'

    if final_status == 'Accepted': total_score = subtask_score
    ET.SubElement(root, 'score').text = str(int(total_score))
    ET.SubElement(root, 'time').text = '0'
    ET.SubElement(root, 'memory').text = '0'
    if final_status != 'Accepted':
        ET.SubElement(root, 'error').text = final_status

    xml = ET.tostring(root, encoding='unicode')
    with open(os.path.join(result_dir, 'result.txt'), 'w') as f: f.write(xml)
    print(xml)

if __name__ == '__main__':
    log(f'wrapper start args={sys.argv[1:]}')
    try:
        main()
        log('wrapper exit 0')
    except Exception as e:
        log(f'wrapper exception: {e}\n{traceback.format_exc()}')
        sys.exit(1)
WRAPPER_EOF

sudo chmod +x "${INSTALL_DIR}/main_judger"
# bwrap --unshare-all 下 azukiiro 用户(UID 映射后)需要写权限
sudo chmod 777 "${INSTALL_DIR}/result" "${INSTALL_DIR}/work"
ok "已部署 ${INSTALL_DIR}/main_judger"
ok "  ├── result/(判题结果输出,权限 777)"
ok "  └── work/(判题工作目录,权限 777)"

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
${C_GREEN}${C_BOLD}  UOJ Judger (Python wrapper) 部署完成!                   ${C_RESET}
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
   sudo journalctl -u azukiiro@daemon -f       # 跟踪评测日志
   cat ${INSTALL_DIR}/result/wrapper.log        # wrapper 调试日志

${C_YELLOW}提示: wrapper 兼容新旧 UOJ judger 格式,直接编译+运行+比对。${C_RESET}
${C_YELLOW}      重复运行本脚本幂等(已部署则跳过;-f 强制重部署)。${C_RESET}
EOF
