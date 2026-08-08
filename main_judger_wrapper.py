#!/usr/bin/python3
"""
AOI / azukiiro UOJ adapter 兼容层
替换 /opt/uoj_judger/main_judger,接受参数: <solution_dir> <problem_dir>
读取 problem.conf + submission.conf → 编译 → 运行 → 比对 → 输出 XML result.txt
"""
import os, sys, shutil, subprocess, tempfile, traceback, resource, signal, xml.etree.ElementTree as ET
from pathlib import Path

LOG_FILE = '/opt/uoj_judger/result/wrapper.log'
def log(msg):
    try:
        with open(LOG_FILE, 'a') as f:
            f.write(f'{msg}\n')
    except:
        pass

def sandbox_exec(cmd, input_data, work_dir, time_limit, mem_limit_mb, output_limit_mb):
    """Run command with resource limits (memory + output). Wall-clock timeout for time."""
    mem_bytes = mem_limit_mb * 1024 * 1024
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

    # Pre-fault memory before measuring rusage baseline
    _ = resource.getrusage(resource.RUSAGE_CHILDREN)
    baseline = resource.getrusage(resource.RUSAGE_CHILDREN)

    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=open(stdout_path, 'w'),
        stderr=open(stderr_path, 'w'),
        cwd=work_dir,
        preexec_fn=preexec,
        text=True
    )

    try:
        proc.communicate(input=input_data, timeout=time_limit + 2)
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        usage = resource.getrusage(resource.RUSAGE_CHILDREN)
        cpu_ms = int((usage.ru_utime - baseline.ru_utime + usage.ru_stime - baseline.ru_stime) * 1000)
        mem_kb = max(0, usage.ru_maxrss - baseline.ru_maxrss)
        try: os.remove(stdout_path)
        except: pass
        try: os.remove(stderr_path)
        except: pass
        return False, "Time Limit Exceeded", cpu_ms, mem_kb, 0
    finally:
        if proc.stdout: proc.stdout.close()
        if proc.stderr: proc.stderr.close()

    # Measure resource usage (CPU time + max memory)
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu_ms = int((usage.ru_utime - baseline.ru_utime + usage.ru_stime - baseline.ru_stime) * 1000)
    mem_kb = max(0, usage.ru_maxrss - baseline.ru_maxrss)

    # Read output with size limit (32MB) to prevent OLE from eating RAM
    MAX_OUT = 32 * 1024 * 1024
    def read_limited(path):
        try:
            with open(path, 'r') as f:
                return f.read(MAX_OUT + 1)
        except: return ''
    stdout = read_limited(stdout_path)
    stderr = read_limited(stderr_path)
    try: os.remove(stdout_path)
    except: pass
    try: os.remove(stderr_path)
    except: pass

    if len(stdout) > MAX_OUT:
        return False, "Output Limit Exceeded", cpu_ms, mem_kb, output_limit_mb * 1024

    if rc == 0:
        return True, stdout, cpu_ms, mem_kb, 0

    # Signal-based exits (negative returncode = killed by signal)
    if rc < 0:
        sig = -rc
        if sig == signal.SIGSEGV:
            return False, "Memory Limit Exceeded", cpu_ms, mem_kb, 0
        if sig == signal.SIGXFSZ:
            return False, "Output Limit Exceeded", cpu_ms, mem_kb, output_limit_mb * 1024
        return False, f"Runtime Error (signal {sig}: {signal.Signals(sig).name})", cpu_ms, mem_kb, 0

    # Non-zero exit codes (rc > 0)
    return False, f"Runtime Error (exit {rc})\n{stderr[:300]}", cpu_ms, mem_kb, 0

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
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30, cwd=work_dir)
        if result.returncode != 0:
            return False, f"Compile Error:\n{result.stderr[:500]}\n{result.stdout[:500]}"
        return True, exec_path
    except subprocess.TimeoutExpired:
        return False, "Compile timeout"
    except FileNotFoundError:
        return False, f"Compiler not found: {cmd[0]}"

def run_test(exec_path, lang, input_file, work_dir, time_limit, mem_limit, output_limit=64):
    """Run compiled program in sandbox (memory/output limits via setrlimit, CPU via wall-clock)."""
    try:
        with open(input_file, 'r') as f:
            input_data = f.read()
    except FileNotFoundError:
        return False, f"Input file not found: {input_file}", 0, 0, 0, 0

    lang_lower = lang.lower()
    if lang_lower.startswith('python'):
        cmd = ['python3', exec_path]
    elif lang_lower == 'java':
        cmd = ['java', '-cp', work_dir, os.path.splitext(os.path.basename(exec_path))[0]]
    else:
        cmd = [exec_path]

    ok, out, cpu_ms, mem_kb, out_kb = sandbox_exec(cmd, input_data, work_dir, time_limit, mem_limit, output_limit)
    return ok, out, cpu_ms, mem_kb, out_kb

def compare_output(actual, expected_file, checker='ncmp'):
    """Compare output with expected."""
    try:
        with open(expected_file, 'r') as f:
            expected = f.read()
    except FileNotFoundError:
        return False, f"Expected output not found: {expected_file}"

    if checker in ('ncmp', 'acmp', 'wcmp'):
        # Normal compare: ignore trailing spaces and final newline
        def normalize(s):
            return '\n'.join(line.rstrip() for line in s.rstrip('\n').split('\n'))
        return normalize(actual) == normalize(expected), "Output mismatch"
    else:
        return actual.strip() == expected.strip(), "Output mismatch"

def main():
    if len(sys.argv) < 3:
        print("Usage: main_judger_wrapper.py <solution_dir> <problem_dir>", file=sys.stderr)
        sys.exit(1)

    sol_dir = sys.argv[1]
    prob_dir = sys.argv[2]
    result_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'result')
    work_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'work')

    log(f'sol_dir={sol_dir} prob_dir={prob_dir} result_dir={result_dir} work_dir={work_dir}')
    log(f'sol_dir exists={os.path.isdir(sol_dir)} prob_dir exists={os.path.isdir(prob_dir)}')
    if os.path.isdir(sol_dir):
        log(f'sol_dir contents: {os.listdir(sol_dir)[:20]}')
    if os.path.isdir(prob_dir):
        log(f'prob_dir contents: {os.listdir(prob_dir)[:20]}')

    os.makedirs(result_dir, exist_ok=True)
    os.makedirs(work_dir, exist_ok=True)

    # Parse configs
    prob_conf = parse_conf(os.path.join(prob_dir, 'problem.conf'))
    sub_conf = parse_conf(os.path.join(sol_dir, 'submission.conf'))

    lang = sub_conf.get('answer_language', 'C++14')

    # Compile
    ok, msg = compile_solution(sol_dir, lang, work_dir)
    if not ok:
        xml = error_result('Compile Error', msg)
        rp = os.path.join(result_dir, 'result.txt')
        try: os.remove(rp)
        except: pass
        with open(rp, 'w') as f:
            f.write(xml)
        print(xml)
        return

    exec_path = msg  # exec path on success

    # Find test cases
    input_suf = prob_conf.get('input_suf', 'in')
    output_suf = prob_conf.get('output_suf', 'out')
    time_limit = max(1, int(prob_conf.get('time_limit', '1')))
    mem_limit = int(prob_conf.get('memory_limit', '256'))

    # Find all test input files
    tests = sorted(Path(prob_dir).glob(f'*.{input_suf}'))
    if not tests:
        tests = sorted(Path(prob_dir).glob('*.in'))

    root = ET.Element('result')
    total_score = 0
    total_time = 0
    total_mem = 0
    final_status = 'Accepted'
    details = ET.SubElement(root, 'details')

    # Default: single subtask
    subtask = ET.SubElement(details, 'subtask', {
        'num': '1',
        'score': prob_conf.get('subtask_score_1', '100'),
        'info': 'Accepted',
        'time': '0',
        'memory': '0',
        'type': 'sum'
    })

    subtask_score = float(prob_conf.get('subtask_score_1', '100'))

    for i, test_in in enumerate(tests, 1):
        test_num = int(''.join(c for c in test_in.stem if c.isdigit()) or i)
        test_out = test_in.with_suffix(f'.{output_suf}')
        if not test_out.exists():
            test_out = test_in.with_suffix('.out')

        ok, output, t, m, o = run_test(exec_path, lang, str(test_in), work_dir, time_limit, mem_limit, int(prob_conf.get('output_limit', '64')))
        total_time += t
        total_mem = max(total_mem, m)

        test_elem = ET.SubElement(subtask, 'test', {
            'num': str(test_num),
            'score': '0',
            'info': 'Accepted',
            'time': str(t),
            'memory': str(m)
        })
        ET.SubElement(test_elem, 'in').text = Path(test_in).read_text(encoding='utf-8', errors='replace')[:500]
        ET.SubElement(test_elem, 'out').text = output[:500] if ok else output
        ET.SubElement(test_elem, 'res').text = ''

        if not ok:
            if 'Time Limit' in output:
                test_elem.set('info', 'Time Limit Exceeded')
                final_status = 'Time Limit Exceeded'
            elif 'Memory Limit' in output:
                test_elem.set('info', 'Memory Limit Exceeded')
                if final_status == 'Accepted':
                    final_status = 'Memory Limit Exceeded'
            elif 'Output Limit' in output:
                test_elem.set('info', 'Output Limit Exceeded')
                if final_status == 'Accepted':
                    final_status = 'Output Limit Exceeded'
            else:
                test_elem.set('info', 'Runtime Error')
                if final_status == 'Accepted':
                    final_status = 'Runtime Error'
            continue

        match, reason = compare_output(output, str(test_out))
        if match:
            test_elem.set('score', str(subtask_score / len(tests)))
            total_score += subtask_score / len(tests)
        else:
            test_elem.set('info', 'Wrong Answer')
            if final_status == 'Accepted':
                final_status = 'Wrong Answer'

    if final_status == 'Accepted':
        total_score = subtask_score

    ET.SubElement(root, 'score').text = str(int(total_score))
    ET.SubElement(root, 'time').text = str(total_time)
    ET.SubElement(root, 'memory').text = str(total_mem)
    if final_status != 'Accepted':
        ET.SubElement(root, 'error').text = final_status

    xml = ET.tostring(root, encoding='unicode')

    # Write result (remove stale file first in case previous run as root left it)
    result_path = os.path.join(result_dir, 'result.txt')
    try: os.remove(result_path)
    except: pass
    with open(result_path, 'w') as f:
        f.write(xml)

    print(xml)

if __name__ == '__main__':
    log(f'wrapper start args={sys.argv[1:]}')
    try:
        main()
        log('wrapper exit 0')
    except Exception as e:
        log(f'wrapper exception: {e}\n{traceback.format_exc()}')
        sys.exit(1)
