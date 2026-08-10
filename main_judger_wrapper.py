#!/usr/bin/python3
"""
AOI / azukiiro UOJ adapter 兼容层
替换 /opt/uoj_judger/main_judger,接受参数: <solution_dir> <problem_dir>
读取 problem.conf + submission.conf → 编译 → 运行 → 比对 → 输出 XML result.txt

输出格式与 azukiiro 的 uoj 适配器 (judge/adapter/uoj/uoj.go) 完全一致:
  <result>
    <score/> <time/> <memory/> [<error/>]
    <details>
      <test num= score= info= time= memory=><in/><out/><res/></test> ...
      [<error/>]
    </details>
  </result>
  - <test> 必须是 <details> 的直接子元素,不要包在 <subtask> 里
  - 任何情况下都以退出码 0 结束,错误信息写进 XML。
    退出码非 0 时适配器会直接报 "An Error has occurred: exit status 1"。
  - 时间限制: UOJ problem.conf 的 time_limit 单位统一为秒,支持小数
    (150 = 150s,0.15 = 150ms),换算成秒作为墙钟超时。TLE 点的 time 按
    题目时限计、memory 取该点实测峰值。memory_limit 单位 MB,同样支持
    小数(如 1.6 = 1.6MB)。
"""
import os, sys, shutil, subprocess, tempfile, traceback, resource, signal, threading
import xml.etree.ElementTree as ET
from pathlib import Path

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
RESULT_DIR = os.path.join(BASE_DIR, 'result')
WORK_DIR = os.path.join(BASE_DIR, 'work')
LOG_FILE = os.path.join(RESULT_DIR, 'wrapper.log')

def log(msg):
    try:
        with open(LOG_FILE, 'a') as f:
            f.write(f'{msg}\n')
    except Exception:
        pass

def truncate(s, n):
    s = s if s is not None else ''
    return s if len(s) <= n else s[:n]

def conf_get(conf, key, default):
    v = conf.get(key)
    return v if v is not None and v.strip() != '' else default

def conf_int(conf, key, default):
    try:
        return int(conf_get(conf, key, default))
    except (ValueError, TypeError):
        log(f'conf_int: cannot parse {key}={conf.get(key)!r}, use default {default}')
        return default

def conf_float(conf, key, default):
    try:
        return float(conf_get(conf, key, default))
    except (ValueError, TypeError):
        log(f'conf_float: cannot parse {key}={conf.get(key)!r}, use default {default}')
        return default

def monitor_memory_kb(pid, stop_event, result):
    """Poll /proc/<pid>/status for VmHWM (peak RSS in kB) until stop_event is set."""
    max_mem = 0
    while not stop_event.is_set():
        try:
            with open(f'/proc/{pid}/status', 'r') as f:
                for line in f:
                    if line.startswith('VmHWM:'):
                        # Format: "VmHWM:    12345 kB"
                        val = int(line.split(':')[1].strip().split()[0])
                        max_mem = max(max_mem, val)
                        break
        except (IOError, OSError, ValueError, IndexError):
            pass
        stop_event.wait(0.05)  # poll every 50ms
    result[0] = max_mem

def sandbox_exec(cmd, input_data, work_dir, time_limit, mem_limit_mb, output_limit_mb):
    """Run command with resource limits (memory + output). Wall-clock timeout for time.

    Returns (ok, status_msg, cpu_ms, mem_kb, out_kb, prog_output):
      ok          - True if the program exited normally with exit code 0
      status_msg  - '' on success; 'Time Limit Exceeded' / 'Memory Limit Exceeded' /
                    'Output Limit Exceeded' / 'Runtime Error (...)' on failure
      prog_output - the program's actual stdout (partial output on timeout/kill,
                    truncated to MAX_OUT) — 用于每个测试点的详细展示
    """
    # 支持小数 MB(如 1.6MB):setrlimit 要求整数字节,按四舍五入取整
    mem_bytes = int(round(mem_limit_mb * 1024 * 1024))
    out_bytes = output_limit_mb * 1024 * 1024

    def preexec():
        # Memory limit via RLIMIT_AS (works in user namespaces)
        if mem_limit_mb > 0:
            resource.setrlimit(resource.RLIMIT_AS, (mem_bytes, mem_bytes))
        # Output limit via RLIMIT_FSIZE (works in user namespaces)
        if output_limit_mb > 0:
            resource.setrlimit(resource.RLIMIT_FSIZE, (out_bytes, out_bytes))
        # NOTE: NOT setting RLIMIT_CPU — it sends SIGKILL directly on Linux,
        # preventing us from distinguishing TLE from other crashes.
        # Time limit is enforced via wall-clock timeout below.

    # Use temporary files for stdout/stderr to avoid buffering in memory
    # (RLIMIT_FSIZE limits the file size, preventing OLE from eating RAM)
    stdout_fd, stdout_path = tempfile.mkstemp(dir=work_dir, prefix='stdout_')
    stderr_fd, stderr_path = tempfile.mkstemp(dir=work_dir, prefix='stderr_')
    os.close(stdout_fd); os.close(stderr_fd)

    # Pre-fault before measuring rusage baseline
    _ = resource.getrusage(resource.RUSAGE_CHILDREN)
    baseline = resource.getrusage(resource.RUSAGE_CHILDREN)

    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=open(stdout_path, 'w'),
        stderr=open(stderr_path, 'w'),
        cwd=work_dir,
        preexec_fn=preexec,
        text=True,
        errors='replace',
    )

    # Start memory monitor thread (polls /proc/<pid>/status VmHWM)
    stop_event = threading.Event()
    mem_result = [0]
    monitor = threading.Thread(target=monitor_memory_kb, args=(proc.pid, stop_event, mem_result))
    monitor.daemon = True
    monitor.start()

    timed_out = False
    try:
        proc.communicate(input=input_data, timeout=time_limit + 2)
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        timed_out = True
        rc = proc.returncode
    finally:
        if proc.stdout: proc.stdout.close()
        if proc.stderr: proc.stderr.close()

    # Stop memory monitor and get peak memory
    stop_event.set()
    monitor.join(timeout=1)
    mem_kb = mem_result[0]

    # Measure CPU time
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu_ms = int((usage.ru_utime - baseline.ru_utime + usage.ru_stime - baseline.ru_stime) * 1000)

    # Read output with size limit (32MB) to prevent OLE from eating RAM
    MAX_OUT = 32 * 1024 * 1024
    def read_limited(path):
        try:
            with open(path, 'r', errors='replace') as f:
                return f.read(MAX_OUT + 1)
        except: return ''
    stdout = read_limited(stdout_path)
    stderr = read_limited(stderr_path)
    try: os.remove(stdout_path)
    except: pass
    try: os.remove(stderr_path)
    except: pass

    # 超时: 保留已产生的部分输出,供 TLE 测试点展示
    if timed_out:
        return False, "Time Limit Exceeded", cpu_ms, mem_kb, 0, stdout

    if len(stdout) > MAX_OUT:
        return False, "Output Limit Exceeded", cpu_ms, mem_kb, output_limit_mb * 1024, stdout[:MAX_OUT]

    if rc == 0:
        return True, '', cpu_ms, mem_kb, 0, stdout

    # Signal-based exits (negative returncode = killed by signal)
    if rc < 0:
        sig = -rc
        if sig == signal.SIGSEGV:
            return False, "Memory Limit Exceeded", cpu_ms, mem_kb, 0, stdout
        if sig == signal.SIGXFSZ:
            return False, "Output Limit Exceeded", cpu_ms, mem_kb, output_limit_mb * 1024, stdout
        return False, f"Runtime Error (signal {sig}: {signal.Signals(sig).name})", cpu_ms, mem_kb, 0, stdout

    # Non-zero exit codes (rc > 0)
    return False, f"Runtime Error (exit {rc})\n{stderr[:300]}", cpu_ms, mem_kb, 0, stdout

def parse_conf(path):
    """Parse key-value conf file (key value per line, first space splits)."""
    conf = {}
    if os.path.exists(path):
        with open(path, encoding='utf-8', errors='replace') as f:
            for line in f:
                line = line.strip()
                if not line or ' ' not in line:
                    continue
                key, value = line.split(' ', 1)
                conf[key.strip()] = value.strip()
    return conf

def error_result_xml(status, message):
    """Build XML for early errors (compile error / system error)."""
    root = ET.Element('result')
    ET.SubElement(root, 'score').text = '0'
    ET.SubElement(root, 'time').text = '0'
    ET.SubElement(root, 'memory').text = '0'
    ET.SubElement(root, 'error').text = status
    details = ET.SubElement(root, 'details')
    ET.SubElement(details, 'error').text = message
    return ET.tostring(root, encoding='unicode')

def write_result_xml(xml_str):
    """Write result XML to result.txt (remove stale file first in case previous run as root left it)."""
    os.makedirs(RESULT_DIR, exist_ok=True)
    rp = os.path.join(RESULT_DIR, 'result.txt')
    try: os.remove(rp)
    except OSError: pass
    with open(rp, 'w', encoding='utf-8') as f:
        f.write(xml_str)

def compile_solution(sol_dir, lang, work_dir):
    """Compile solution, return (success, exec_path or error_msg)."""
    # Find source files
    sources = []
    for ext in ['.cpp', '.cc', '.cxx', '.c', '.pas', '.py', '.java']:
        sources.extend(Path(sol_dir).glob(f'*{ext}'))

    if not sources:
        return False, "No source file found"

    src = sources[0]
    exec_path = os.path.join(work_dir, 'program')

    lang_lower = lang.lower()

    if lang_lower in ('c++', 'c++11', 'c++14', 'c++17'):
        cmd = ['g++', '-std=c++17', '-O2', '-o', exec_path, str(src)]
    elif lang_lower.startswith('python'):
        # Copy the Python script
        shutil.copy(str(src), exec_path + '.py')
        return True, exec_path + '.py'
    elif lang_lower == 'java':
        cmd = ['javac', '-d', work_dir, str(src)]
    elif lang_lower == 'pascal':
        cmd = ['fpc', '-O2', '-o' + exec_path, str(src)]
    else:
        return False, f"Unsupported language: {lang}"

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30,
                                cwd=work_dir, errors='replace')
        if result.returncode != 0:
            return False, f"Compile Error:\n{result.stderr[:500]}\n{result.stdout[:500]}"
        if lang_lower == 'java':
            # javac 按源文件名生成 .class,运行入口取其文件名
            classes = list(Path(work_dir).glob('*.class'))
            if not classes:
                return False, "Compile Error: no .class output produced"
            return True, str(classes[0])
        return True, exec_path
    except subprocess.TimeoutExpired:
        return False, "Compile timeout"
    except FileNotFoundError:
        return False, f"Compiler not found: {cmd[0]}"

def run_test(exec_path, lang, input_file, work_dir, time_limit, mem_limit, output_limit=64):
    """Run compiled program in sandbox (memory/output limits via setrlimit, CPU via wall-clock)."""
    try:
        with open(input_file, 'r', errors='replace') as f:
            input_data = f.read()
    except FileNotFoundError:
        return False, f"Input file not found: {input_file}", 0, 0, 0, 0, ''

    lang_lower = lang.lower()
    if lang_lower.startswith('python'):
        cmd = ['python3', exec_path]
    elif lang_lower == 'java':
        cmd = ['java', '-cp', os.path.dirname(exec_path), os.path.splitext(os.path.basename(exec_path))[0]]
    else:
        cmd = [exec_path]

    return sandbox_exec(cmd, input_data, work_dir, time_limit, mem_limit, output_limit)

def short_value(v):
    """截断单个值到最多 20 字符,用于 WA 等错误信息的 expected/found 展示。"""
    v = str(v)
    return v if len(v) <= 20 else v[:20]

def ordinal(n):
    """1st / 2nd / 3rd / 4th ..."""
    if 10 <= n % 100 <= 20:
        suffix = 'th'
    else:
        suffix = {1: 'st', 2: 'nd', 3: 'rd'}.get(n % 10, 'th')
    return f'{n}{suffix}'

def compare_output(actual, expected_file, checker='ncmp'):
    """Compare output with expected. Returns (match, result_message)."""
    try:
        with open(expected_file, 'r') as f:
            expected = f.read()
    except FileNotFoundError:
        return False, f"Expected output not found: {expected_file}"

    actual_lines = [line.rstrip() for line in actual.rstrip('\n').split('\n')]
    expected_lines = [line.rstrip() for line in expected.rstrip('\n').split('\n')]

    # Line count mismatch
    if len(actual_lines) != len(expected_lines):
        min_len = min(len(actual_lines), len(expected_lines))
        if len(actual_lines) > len(expected_lines):
            return False, f"wrong answer too many lines - expected: '{short_value(expected_lines[-1] if expected_lines else 'EOF')}', found: '{short_value(actual_lines[min_len])}'"
        else:
            return False, f"wrong answer too few lines - expected: '{short_value(expected_lines[min_len])}', found: '{short_value(actual_lines[-1] if actual_lines else 'EOF')}'"

    # Token-by-token comparison per line
    for i, (a_line, e_line) in enumerate(zip(actual_lines, expected_lines), 1):
        a_tokens = a_line.split()
        e_tokens = e_line.split()
        if a_tokens != e_tokens:
            return False, f"wrong answer {ordinal(i)} numbers differ - expected: '{short_value(e_line)}', found: '{short_value(a_line)}'"

    return True, f"ok {len(actual_lines)} numbers"

def main():
    if len(sys.argv) < 3:
        xml = error_result_xml('System Error', 'Usage: main_judger <solution_dir> <problem_dir>')
        write_result_xml(xml)
        print(xml)
        return

    sol_dir = sys.argv[1]
    prob_dir = sys.argv[2]

    log(f'sol_dir={sol_dir} prob_dir={prob_dir} result_dir={RESULT_DIR} work_dir={WORK_DIR}')
    log(f'sol_dir exists={os.path.isdir(sol_dir)} prob_dir exists={os.path.isdir(prob_dir)}')
    if os.path.isdir(sol_dir):
        log(f'sol_dir contents: {os.listdir(sol_dir)[:20]}')
    if os.path.isdir(prob_dir):
        log(f'prob_dir contents: {os.listdir(prob_dir)[:20]}')

    os.makedirs(RESULT_DIR, exist_ok=True)
    os.makedirs(WORK_DIR, exist_ok=True)

    # Parse configs
    prob_conf = parse_conf(os.path.join(prob_dir, 'problem.conf'))
    sub_conf = parse_conf(os.path.join(sol_dir, 'submission.conf'))

    lang = sub_conf.get('answer_language', 'C++14')

    # time_limit 单位统一为秒,支持小数(150 = 150s,0.15 = 150ms);
    # 换算成毫秒供 TLE 显示;墙钟超时保留小数精度(最小 0.05s)
    time_limit_ms = conf_float(prob_conf, 'time_limit', 1.0) * 1000
    time_limit_sec = max(0.05, time_limit_ms / 1000.0)
    # memory_limit 单位 MB,支持小数(如 1.6 = 1.6MB);内部按字节取整
    mem_limit_mb = conf_float(prob_conf, 'memory_limit', 256.0)
    output_limit_mb = conf_int(prob_conf, 'output_limit', 64)
    input_suf = conf_get(prob_conf, 'input_suf', 'in')
    output_suf = conf_get(prob_conf, 'output_suf', 'out')

    # Compile
    ok, msg = compile_solution(sol_dir, lang, WORK_DIR)
    if not ok:
        xml = error_result_xml('Compile Error', msg)
        write_result_xml(xml)
        print(xml)
        return

    exec_path = msg  # exec path on success

    # Find test cases
    test_files = sorted(Path(prob_dir).glob(f'*.{input_suf}'))
    if not test_files:
        test_files = sorted(Path(prob_dir).glob('*.in'))
    if not test_files:
        xml = error_result_xml('System Error',
                               f'No test data (*.{input_suf}) found in {prob_dir}\nprob contents: {os.listdir(prob_dir)[:20]}')
        write_result_xml(xml)
        print(xml)
        return

    subtask_score = conf_float(prob_conf, 'subtask_score_1', 100.0)
    # 每测试点分值用浮点数保留精度:若取整(如 101 点 100 分时每点 int(0.99)=0),
    # 会出现"过 99 个点只得 0 分、全对才满分"的失真,最终总分再四舍五入
    test_score = subtask_score / len(test_files)

    total_score = 0.0
    final_status = 'Accepted'
    total_time = 0
    max_mem = 0  # 顶层 memory 取所有测试点运行内存的最大值

    root = ET.Element('result')
    details = ET.SubElement(root, 'details')

    for i, test_in in enumerate(test_files, 1):
        test_out = test_in.with_suffix(f'.{output_suf}')
        if not test_out.exists():
            test_out = test_in.with_suffix('.out')

        ok_run, status_msg, t_ms, m_kb, _out_kb, prog_out = run_test(
            exec_path, lang, str(test_in), WORK_DIR,
            time_limit_sec, mem_limit_mb, output_limit_mb
        )

        # Determine test status
        test_status = 'Accepted'
        res_msg = ''
        if not ok_run:
            if 'Time Limit' in status_msg:
                test_status = 'Time Limit Exceeded'
            elif 'Memory Limit' in status_msg:
                test_status = 'Memory Limit Exceeded'
            elif 'Output Limit' in status_msg:
                test_status = 'Output Limit Exceeded'
            else:
                test_status = 'Runtime Error'
            res_msg = status_msg
        else:
            match, res_msg = compare_output(prog_out, str(test_out))
            if not match:
                test_status = 'Wrong Answer'

        # 每个测试点都输出详细 Time/Memory/Input/Output/Result(与 AC 一致);
        # TLE 点按题目时间限制计(超时即视为用满时限),内存取该点实测峰值;
        # MLE 点被内存限制强杀,监控可能采不到真实峰值,按题目上限显示
        if test_status == 'Time Limit Exceeded':
            t_disp, m_disp = int(round(time_limit_ms)), m_kb
        elif test_status == 'Memory Limit Exceeded':
            t_disp, m_disp = t_ms, int(round(mem_limit_mb * 1024))
        else:
            t_disp, m_disp = t_ms, m_kb

        score = test_score if test_status == 'Accepted' else 0.0
        total_score += score
        if test_status != 'Accepted' and final_status == 'Accepted':
            final_status = test_status
        # 顶层 time 汇总所有测试点用时(TLE 计为题目时限);memory 取所有测试点的最大值
        total_time += t_disp
        max_mem = max(max_mem, m_disp)

        # Input for display (truncated)
        try:
            raw_in = Path(test_in).read_text(encoding='utf-8', errors='replace')
        except Exception:
            raw_in = ''

        test = ET.SubElement(details, 'test', {
            'num': str(i),
            # 测试点分值同样取整展示(azukiiro 适配器按整数解析,浮点字符串会解析失败)
            'score': str(int(round(score))),
            'info': test_status,
            'time': str(t_disp),
            'memory': str(m_disp),
        })
        ET.SubElement(test, 'in').text = truncate(raw_in, 500)
        ET.SubElement(test, 'out').text = truncate(prog_out, 500)
        ET.SubElement(test, 'res').text = truncate(res_msg, 500)

    # 浮点累加后统一四舍五入为整数输出(全对时 ≈ subtask_score,与原特判等效;
    # 部分正确则按实际通过比例计分)
    total_score_display = int(round(total_score))

    # 重要: 测试点级失败(WA/TLE/MLE/OLE/RE)不要在 result 级写 <error>。
    # azukiiro 适配器逻辑: result.Error 非空时直接跳过 <details> 测试点解析,
    # 导致非 AC 结果没有具体测试点详情。状态由各 <test info=> 推导即可。
    # 只有无测试点的错误(编译错误/系统错误)才由 error_result_xml 带 <error>。
    ET.SubElement(root, 'score').text = str(total_score_display)
    ET.SubElement(root, 'time').text = str(total_time)
    ET.SubElement(root, 'memory').text = str(max_mem)

    xml = ET.tostring(root, encoding='unicode')
    write_result_xml(xml)
    print(xml)

if __name__ == '__main__':
    log(f'wrapper start args={sys.argv[1:]}')
    try:
        main()
        log('wrapper exit 0')
    except Exception as e:
        log(f'wrapper exception: {e}\n{traceback.format_exc()}')
        xml = error_result_xml('System Error', f'{e}\n{traceback.format_exc()}')
        try:
            write_result_xml(xml)
        except Exception:
            pass
        print(xml)
    # 永远以 0 退出:退出码非 0 时 azukiiro 适配器报 "exit status 1"
    sys.exit(0)
