# docs-lint

给 reviewer Agent 生成结构化事实包：脚本负责结构、证据与可维护性，Agent 负责可用性判断。

它面向任何用 Markdown 长期维护的文档库：产品手册、知识库、项目文档、个人笔记都可以。规则由配置驱动，不绑定某个仓库的目录约定。

---

## 快速开始

```powershell
git clone https://github.com/cixia6944-cloud/docs-lint.git docs-lint
cd docs-lint
pwsh -NoProfile -File tools/demo.ps1
```

`demo.ps1` 会把 `fixtures/good` 和 `fixtures/bad` 复制到临时目录，各自 `git init`，然后跑分类检查和凭据自查。预期结果是：

- `good`：exit 0
- `bad`：exit 1（违规词、无来源日期、日期格式、编码可疑、未跟踪草稿）
- `bad` 的凭据扫描：exit 1（假口令）

临时目录默认跑完删除；加 `-Keep` 可以保留现场。

---

## 两个工具

### `tools/audit-docs.ps1`：文档一致性检查

按 `docs-lint.config.json` 里的分类规则检查 `.md`：

```powershell
# 检查当前仓库（默认读仓库根目录的 docs-lint.config.json）
pwsh -NoProfile -File tools/audit-docs.ps1 -Repo .

# 只输出一行 JSON，给 CI / agent 用
pwsh -NoProfile -File tools/audit-docs.ps1 -Repo . -Json

# 换一份配置
pwsh -NoProfile -File tools/audit-docs.ps1 -Repo . -Config path/to/config.json
```

它会生成一份可 diff 的事实包，供 reviewer Agent 判断。当前内置这些机械检查：

1. **分类**：按路径 glob 把每篇文档分到 `current`、`history`、`data` 等类别。
2. **违规词**：`checkBadWords` 为 true 的类别，用 `audit/rules.json` 的词表检查历史叙述词。
3. **日期来源**：`datePolicy: sourced` 的类别，日期必须出现在允许的上下文里（文件头标记、验证行、表格、路径、行内代码）。
4. **证据与残留**：检查没有证据锚的完成性表述、正文 TODO、以及指向不存在文件或行号的引用。
5. **未跟踪文件**：内容照扫，并单独报一条 `untracked`，提醒你 `git add` 或加进 `.gitignore`。

`-FactPack <path>` 会把 `coverage / findings / totals` 写成稳定 JSON；`-Baseline <path>` 按稳定 id 对比上一份事实包，`-FailOnNew` 只对新增 finding 阻断。

### `tools/check-secrets.ps1`：凭据自查

扫描 git 跟踪的明文文件，报告疑似口令/密钥的位置：

```powershell
pwsh -NoProfile -File tools/check-secrets.ps1 -Repo .
pwsh -NoProfile -File tools/check-secrets.ps1 -Staged
pwsh -NoProfile -File tools/check-secrets.ps1 -Exclude 'docs/security.md','fixtures/*'
```

它**只报告，不阻止提交**。输出只有「规则 + 文件 + 行号」，不打印命中的原文。工具自身和 `tools/selftest.ps1` 默认跳过：后者装着自测用的假凭据，不排除会天天自报。

### `tools/selftest.ps1`：自测

```powershell
pwsh -NoProfile -File tools/selftest.ps1
```

在临时目录造一份干净样例和一份坏样例，断言检查器会放行、会拦、会在配置坏掉时失败，而不是一直打 OK。改完 `tools/` 下任何脚本都建议跑一遍。

---

## 配置

默认配置文件是仓库根目录的 `docs-lint.config.json`，可以用 `-Config` 指定别的路径。完整示例：

```json
{
  "categories": [
    {
      "name": "history",
      "match": ["history/*", "archive/*", "*/history/*"],
      "datePolicy": "free",
      "checkBadWords": false,
      "warnIfNoDate": true
    },
    {
      "name": "current",
      "match": ["*"],
      "datePolicy": "sourced",
      "checkBadWords": true,
      "warnIfDateDense": true
    }
  ],
  "dateRules": {
    "headerLines": 15,
    "headerMarkers": ["updated", "last updated", "date"],
    "verifyWords": ["verified", "tested"],
    "allowTableRows": true,
    "allowPathDates": true,
    "allowInlineCode": true,
    "allowBlockquoteHeader": true
  },
  "dateStyle": "warn",
  "dateCap": 8,
  "blockOn": "all",
  "rules": {
    "claimUnsupported": {
      "severity": "warn",
      "claims": ["已修复", "验证过", "done"],
      "commands": ["pwsh", "git", "curl"]
    },
    "todoResidue": {
      "severity": "error",
      "words": ["TODO", "FIXME", "待补"],
      "allowTodoFiles": ["TODO.md", "AGENTS.md"]
    },
    "staleReference": {
      "severity": "error",
      "extensions": [".md", ".ps1", ".py", ".sh", ".json"]
    }
  },
  "untracked": "error",
  "rulesFile": "audit/rules.json"
}
```

### `categories`

有序数组。每个文件从上到下匹配 `match` 里的 PowerShell 通配符，**第一个命中的分类生效**，所以 catch-all（`"*"`）必须放最后。

`match` 匹配的是相对仓库根目录、用 `/` 分隔的路径。`*` 可以跨目录，例如 `*/history/*` 能匹配 `fixtures/good/history/note.md`。

每类可用的字段：

| 字段 | 默认 | 说明 |
|---|---|---|
| `name` | 必填 | 分类名，出现在统计和 JSON 里 |
| `match` | 必填 | 路径 glob 数组 |
| `datePolicy` | `ignore` | `sourced` / `free` / `ignore` |
| `checkBadWords` | `false` | 是否用 `badWords` 检查 |
| `warnIfNoDate` | `false` | 该分类一篇日期都没有时提示（适合历史类） |
| `warnIfDateDense` | `false` | 日期数达到 `dateCap` 时提示（适合现状类） |

没有任何分类匹配的文件会报 `no-category` 并 exit 1，不会静默跳过。配置漏了也是错，不是「没规则所以通过」。

### `datePolicy`

- `sourced`：日期必须有上下文来源。允许的形式：
  - 文件头部区域（前 `headerLines` 行）里的版本标记，或 `>` 开头的块引用；
  - 含 `verifyWords` 里任意词的行；
  - 表格行（`allowTableRows`）；
  - 含 `.md` 且带路径分隔符的行（`allowPathDates`）；
  - 行内代码里的日期（`allowInlineCode`）。

  不认识的常见日期写法（`MM/DD/YYYY`、`YYYY/M/D`、`D.M.YYYY`、无补零 ISO、英文月份格式）会报 `date-style`，要求统一成 `YYYY-MM-DD` 或 `YYYY年M月`。`date-style` 只作用于 `sourced` 分类；若某个分类要单独开关，配置分类级 `checkDateStyle`。
- `free`：日期不受限。适合历史、数据、排障记录。
- `ignore`：完全不检查日期。适合 README、元文档、fixture。

代码块（``` 或 ~~~ 围起来的部分，且结束标记必须使用相同字符）里的日期一律跳过，那里的日期是示例数据。

所有参与内容检查的 Markdown 必须是严格 UTF-8。解码失败会报 `encoding-suspect`，该文件不参与后续内容检查；先转码再复查，避免乱码被静默当成合规。

### `dateRules`

日期上下文的启发式判据。`headerMarkers` 和 `verifyWords` 按字面量匹配（会转义正则元字符），大小写不敏感。如果你们的文档习惯用 `Last updated:`、`Reviewed on` 之类，改这里就行，不用改代码。

### `dateStyle`

控制 `sourced` 分类里可疑日期写法的处理方式（分类级 `checkDateStyle` 默认跟随 `datePolicy`）：

- `off`：不检查；
- `warn`（默认）：进 `warnings`，不阻断；
- `error`：进 `issues`，exit 1。

可疑写法先在剩余文本里匹配，已识别的规范日期会先被等长抹除，避免 `2026-11-18` 被 `2026-11` 污染。`date-style` 复用围栏、行内代码和 `.md` 路径行的豁免；同一行仍会继续执行日期来源判定。提示会直接给出改写结果，例如 `2026/03/05 → 2026-03-05`。

### `dateCap`

日期密度阈值，默认 8。达到阈值只发 warn，不阻断。它表达的是一个经验判断：**一篇现状文档里日期越来越多，通常说明它正在变成变更记录，该把历史部分拆出去了**。密度本身不是错误，所以不拦。

### `blockOn`

控制哪些 error 会让进程退出 1：

- `fact`（默认）：只有事实型 error 阻断，启发式 error 在 FactPack 中降级为 warn；
- `all`：所有 error 都阻断。

### `rules`

三条证据与残留规则都由 `rules` 配置驱动，`severity` 支持 `off`、`warn`、`error`。

- `claimUnsupported.claims` 是完成性表述词表，`commands` 是可作证据锚的命令词表。规则只作用于 `datePolicy: sourced` 的分类，代码块内不判。同/下一行有 URL、`文件:行`、7-40 位十六进制 commit、行内命令，或紧邻代码块至少两行输出时视为有证据。
- `todoResidue.words` 是正文待办词表；`allowTodoFiles` 默认允许 `TODO.md` 和 `AGENTS.md` 承载待办。
- `staleReference.extensions` 是要检查的仓库相对路径扩展名。文件不存在或 `文件:行` 的行号超出实际范围会报；URL、绝对路径、占位符写法和仓库外路径跳过。

### `untracked`

未跟踪 `.md` 的处理方式：

- `error`（默认）：报错并 exit 1；
- `warn`：只提示；
- `ignore`：不报（内容仍然会扫）。

### `rulesFile`

违规词文件，相对配置文件所在目录解析。默认 `audit/rules.json`。也可以用命令行 `-Rules` 覆盖。

---

## 违规词模板

`audit/rules.json`：

```json
{
  "badWords": [
    "曾经",
    "以前\\s*是",
    "后来改"
  ]
}
```

每个元素是**正则片段**，不是字面量。工具用 `|` 把它们拼成一个正则，所以：

- 纯文字直接写；
- 要匹配「以前是」和「以前 是」两种写法，写 `以前\\s*是`；
- 含正则元字符（`. * + ? | ( ) [ ] { } ^ $ \`）时自己转义。

模板里保留三个通用示例，实际使用时换成你们文档里真正想禁掉的叙述词。

**为什么外置？** 违规词是判据数据，不是代码。外置之后：

- 加一条词只改 JSON，不需要碰脚本，也不需要为了一个词重跑整套自测；
- 词表改动能在 diff 里单独审查；
- 不同仓库可以带自己的词表，而工具只维护一份。

**但绝不退回内置词表。** 文件缺失、解析失败、`badWords` 为空、正则非法，一律 exit 1。理由见下面的「假绿」。

---

## 设计取舍

### 为什么未跟踪的 `.md` 也要扫

`git ls-files` 只列已入库的文件。新写的文档在 `git add` 之前是「未跟踪」状态，这个状态很常见，而且很容易被检查器漏掉：它既不在历史里，也不进备份，检查器却可能打出一句「全部合规」。

更糟的是，这种漏检不会报错。工具会看起来正常工作，只是没看那些文件。

所以这里做两件事：

1. 把未跟踪的 `.md` 加进扫描列表，内容照扫；
2. 单独报一条 `untracked`，逼你做决定：`git add`，或者加进 `.gitignore` 明确表示它不该入库。

代价是：刚写草稿时检查会失败。这是故意的，草稿也应该先纳入版本控制，或者明确排除。

### 什么是「假绿」

**假绿 = 工具报告通过，但它实际上没有按你以为的范围和规则检查。**

常见的产生方式：

- 词表读不到，工具悄悄用内置词表继续跑；
- 未跟踪文件不在 `git ls-files` 里，于是压根没扫；
- 编码不对，中文文件名变成乱码，`Test-Path` 全部落空，文件被静默跳过；
- 配置里没有匹配的分类，文件被当成「不需要检查」；
- 词表是空的，任何文档都「没有命中」。

这些情况的共同点是：**没有异常，没有红字，只有一句 OK**。等到有人依赖这句 OK 做决定时，问题已经过去了。

所以本工具的原则是：**只要无法建立判断，就 exit 1，而不是 exit 0。**

- 配置文件缺失 / 解析失败 / `categories` 为空 → exit 1；
- 分类缺 `name` / `match` / `datePolicy` 非法 → exit 1；
- 规则文件缺失 / 解析失败 / `badWords` 为空 / 正则非法 → exit 1；
- 文件没有匹配的分类 → `no-category`，exit 1。

不提供「读不到就用默认值」的开关。默认值会让配置错误变成静默行为变化，而这正是假绿最舒服的藏身之处。

### 日期密度为什么是拆文件信号

一篇「现状」文档如果不断追加日期，它通常已经在承担变更记录的职责。读者想查「现在是什么」，却要先翻过一串「某年某月改过什么」。

`dateCap` 因此是一个提示而不是错误：

- 达到阈值 → warn，提醒你检查是否还有该拆出去的部分；
- 拆出去的日期进 `history/`，现状文档只留当前事实；
- 历史文档的日期不受限，因为它本来就是按时间组织的。

阈值默认 8，可按文档习惯调整。它不是精确科学，只是一个让「该拆了」变得可见的信号。

### 为什么凭据扫描不打印原文

凭据扫描器本身可能成为泄漏渠道：日志、终端回滚、CI 输出、截图，都会把命中的原文带出去。

所以 `check-secrets.ps1` 只输出规则名、文件名、行号。需要看具体内容时，人去文件里看。

它还会在结论里写明扫描范围（扫了多少个文件、跳过了多少、有多少个 git 记录但磁盘上不存在）。**「零命中」如果不交代范围，就是另一种假绿。**

### 为什么默认只扫 git 跟踪的文件

git 跟踪集合是可复现、可审查的：同一份仓库，任何时候扫出来的范围一致。全盘扫描会把缓存、构建产物、临时文件都卷进来，结论不稳定。

需要扫暂存区时用 `-Staged`。`.gitignore` 排除的文件需要你先决定要不要纳入版本库；工具不会替你猜。

---

## 退出码

| 工具 | 0 | 1 | 2 |
|---|---|---|---|
| `audit-docs.ps1` | 干净 | 有违规，或配置/词表不可用 | 不是 git 仓库、找不到 git、目录不存在 |
| `check-secrets.ps1` | 未发现 | 发现疑似凭据 | 不是 git 仓库、找不到 git、目录不存在 |
| `selftest.ps1` | 全过 | 有失败项 | 环境问题 |

`audit-docs.ps1 -Json` 输出一行对象，主要字段：

```json
{
  "schema_version": 1,
  "tool": "audit-docs",
  "repo": "...",
  "config": "...",
  "rules": "...",
  "ok": false,
  "exit_code": 1,
  "counts": { "current": 2, "history": 1 },
  "issues": [
    { "category": "current", "rule": "badword", "severity": "error", "file": "guide.md", "line": 3, "detail": "..." }
  ],
  "warnings": [],
  "error": null
}
```

---

## 依赖与 PowerShell 差异

- **PowerShell 7+**：推荐。
- **Windows PowerShell 5.1**：可以用，但要注意：
  - `.ps1` 必须存成 **UTF-8 with BOM**。5.1 会把无 BOM 的 UTF-8 按系统 ANSI 编码读，中文全变乱码，甚至语法报错。`tools/selftest.ps1` 会检查这一点。
  - 读取 git 输出时，工具会临时把 `[Console]::OutputEncoding` 钉成 UTF-8。否则在 GBK 控制台里，中文文件名会解成乱码，`Test-Path` 落空，文件被静默跳过。
  - 5.1 下原生程序的 stderr 有时会被当成终止性错误。自测里对预期内的失败做了 `2>&1` 包装；日常使用如果遇到，先把 `$ErrorActionPreference` 调成 `Continue` 再试。
- **git**：两个工具都依赖它判断跟踪状态。
- 不需要任何 PowerShell 模块。

调用时用 `pwsh -NoProfile -File ...`，避免用户 profile 里的别名或执行策略干扰。

---

## 已知限制

- **日期检查是启发式**，不是语义分析。它只把 `YYYY-MM-DD`、`YYYYMMDD`、`YYYY年M月` 当作规范格式；常见英文日期会被报成 `date-style`，更冷门的自定义写法仍可能识别不到。需要时改代码里的 `$reDate` / `$reSuspectDate`。
- **分类按路径 glob 匹配**，不读 front matter，也不理解文档结构。路径改了，配置要跟着改。
- **违规词是正则片段**，写得太宽会误报，写得太窄会漏报。它适合禁掉少数几个明确的叙述词，不适合做完整的写作规范。
- **只检查 `.md`**。其他扩展名不参与分类和日期检查。
- **未跟踪检查只针对 `.md`**。其他类型的未跟踪文件不会报。
- **`check-secrets.ps1` 是正则扫描**，没有熵检测，不解压压缩包，不扫描 `.gitignore` 排除的文件，也不扫描二进制文件。它会误报（用 `-Exclude` 处理），也会漏报（正则没覆盖的形态）。
- **不自动修复**。工具只报告，改动由人做。
- **不检查链接、标题层级、拼写、字数**。这些应该交给专门工具。
- **非严格 UTF-8 的 Markdown 会报 `encoding-suspect`**，不参与后续内容检查。请先统一编码，再复查。

---

## 目录结构

```text
docs-lint/
├─ docs-lint.config.json     分类与日期规则
├─ audit/
│  └─ rules.json             违规词模板
├─ tools/
│  ├─ audit-docs.ps1         文档一致性检查
│  ├─ check-secrets.ps1      凭据自查
│  ├─ demo.ps1               一条命令看效果
│  └─ selftest.ps1           工具自测
├─ fixtures/
│  ├─ good/                  应当通过的样例
│  └─ bad/                   故意写坏的样例
└─ README.md
```

---

## 接入 CI

```yaml
- name: docs lint
  shell: pwsh
  run: |
    pwsh -NoProfile -File tools/audit-docs.ps1 -Repo .
    pwsh -NoProfile -File tools/check-secrets.ps1 -Repo .
```

`audit-docs.ps1` 的 exit code 可以直接作为关卡；`check-secrets.ps1` 默认也是发现即 exit 1，如果只想报告不想拦，在 CI 里加 `continue-on-error: true`。

---

## 来历

这套检查器最初来自一个长期维护的中文文档库，用来防止「现状文档混进历史叙述」和「日期没有来源」这两类漂移。抽出来时去掉了仓库特定的分类名、路径和词表，改成配置驱动，保留的是判据和失败策略。
