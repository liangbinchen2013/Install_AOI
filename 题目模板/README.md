# AOI 题目模板

复制本文件夹,修改内容后打包上传即可创建题目。

## 文件结构

```
题目模板/
├── problem.json     ← 题目元数据(粘贴到前端编辑器的 Config 框)
├── problem.conf     ← 评测配置(打包进数据 zip)
├── tests/           ← 测试数据(打包进数据 zip)
│   ├── 1.in         ← 第 1 组输入
│   ├── 1.out        ← 第 1 组期望输出
│   ├── 2.in         ← 第 2 组输入
│   └── 2.out        ← 第 2 组期望输出
└── sol.cpp          ← 参考解法(不参与评测,仅用于本地验证)
```

## 一、创建题目

### 步骤 1: 打包数据

把 `problem.conf` + `tests/` 打包为 `data.zip`:

```bash
zip -r data.zip problem.conf tests/
```

### 步骤 2: 在前端创建题目

1. 进入 AOI → 组织 → Problems → 新建
2. 填写标题、Slug(URL 标识)、题面(Markdown)
3. 在 **Config** 框中粘贴 `problem.json` 的内容
4. 上传 `data.zip`
5. 保存

### 步骤 3: 验证

提交 `sol.cpp` 中的参考解法,应得到 AC 100。

---

## 二、problem.json 配置说明

```jsonc
{
  "label": "uoj",              // 评测标签,必须匹配 azukiiro runner 的 labels
  "judge": {
    "adapter": "uoj",           // 评测适配器: uoj(传统 OI) / deno(脚本判题) / flag(CTF)
    "config": {}                // 适配器额外配置,通常留空
  },
  "submit": {
    "upload": true,             // 开启"上传文件"提交方式
    "zipFolder": true,          // 开启"上传目录"提交方式
    "form": {                   // 开启"可视化 IDE"提交方式(可选)
      "files": [
        {
          "path": "main.cpp",              // 生成 zip 中的文件名
          "label": "Main Code",            // 编辑器标签
          "type": { "editor": { "language": "cpp" } }  // 语法高亮: cpp/c/python/java/pas
        }
      ]
    }
  },
  "instanceLabel": "uoj"       // 允许创建 Instance(可选)
}
```

**常见配置组合:**

| 场景 | submit 配置 |
|---|---|
| 只允许上传 zip | `"submit": { "upload": true, "zipFolder": true }` |
| 在线 IDE + 上传 | 上面加上 `"form": { "files": [...] }` |
| CTF flag 题 | `"judge": { "adapter": "flag", "config": { "flag": "flag{xxx}" } }` |

---

## 三、problem.conf 字段说明

每行格式: `key value`(单空格分隔,不支持 Tab)

| 字段 | 必填 | 说明 | 示例 |
|---|---|---|---|
| `n_tests` | ✓ | 测试数据组数 | `n_tests 10` |
| `n_ex_tests` | ✓ | 额外测试组数(通常为 0) | `n_ex_tests 0` |
| `n_sample_tests` | ✓ | 样例组数 | `n_sample_tests 0` |
| `input_pre` | | 输入文件前缀(留空=无前缀) | 留空或 `input_pre ` |
| `input_suf` | ✓ | 输入文件后缀 | `input_suf in` |
| `output_pre` | | 输出文件前缀 | 留空或 `output_pre ` |
| `output_suf` | ✓ | 输出文件后缀 | `output_suf out` |
| `time_limit` | ✓ | 时间限制(秒) | `time_limit 1` |
| `memory_limit` | ✓ | 内存限制(MB) | `memory_limit 256` |
| `output_limit` | | 输出大小限制(MB,默认 64) | `output_limit 64` |
| `subtask_score_1` | ✓ | 子任务 1 总分 | `subtask_score_1 100` |

**测试文件命名规则:**

- 文件名 = `input_pre` + 编号 + `.` + `input_suf`
- 如果 `input_pre` 为空、`input_suf` = `in`,则文件名为 `1.in`, `2.in`, ...
- 输出文件同理

---

## 四、多子任务配置

如果有多个子任务(Subtask),在 `problem.conf` 中追加:

```
n_tests 10
subtask_score_1 30     # 子任务 1: 测试 1-5, 满分 30
subtask_score_2 70     # 子任务 2: 测试 6-10, 满分 70
```

然后在问题数据中包含 `1.in` ~ `10.in` 和 `1.out` ~ `10.out`。

---

## 五、常见错误

### ❌ problem.conf 含 CRLF 换行符
用 VS Code / Notepad++ 确保文件是 LF 换行,不是 CRLF。

```bash
# 修复: 用 sed 转换
sed -i 's/\r$//' problem.conf
```

### ❌ submit 三个字段全空 → 提交页空白
至少开启 `upload`、`zipFolder`、`form` 之一。参见 [提交页面空白解决方案.md](../文档/提交页面空白解决方案.md)。

### ❌ label 不匹配 runner
`problem.json` 的 `label` 必须包含在 azukiiro runner 的 `labels` 里。
当前默认 runner 有 labels: `default`, `ranker`, `uoj`。

### ❌ 忘记 n_tests 导致评测失败
`n_tests` 必须与实际测试文件数量一致,否则 judger 报错。

### ❌ 测试文件命名不一致
`input_suf` 写了 `in`,但测试文件叫 `1.txt` → 需要改成 `1.in` 或把 `input_suf` 改成 `txt`。

---

## 六、本地验证评测

部署 AOI 全套环境后,可以手动运行评测器验证问题配置:

```bash
# 模拟评测流程(bwrap 会创建沙箱运行 wrapper)
SOL=/path/to/sol_dir    # 包含 main.cpp + submission.conf
PROB=/path/to/prob_dir  # 包含 problem.conf + tests/

bwrap \
  --dir /tmp --dir /var \
  --bind "$SOL" /tmp/solution \
  --ro-bind "$PROB" /tmp/problem \
  --ro-bind /opt/uoj_judger /opt/uoj_judger \
  --bind /opt/uoj_judger/result /opt/uoj_judger/result \
  --bind /opt/uoj_judger/work /opt/uoj_judger/work \
  --ro-bind /usr /usr \
  --symlink ../tmp var/tmp --proc /proc --dev /dev \
  --ro-bind /etc/resolv.conf /etc/resolv.conf \
  --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
  --symlink usr/bin /bin --symlink usr/sbin /sbin \
  --chdir /opt/uoj_judger --unshare-all --die-with-parent \
  /opt/uoj_judger/main_judger /tmp/solution /tmp/problem

cat /opt/uoj_judger/result/result.txt
```
