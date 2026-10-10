# Codex Input Unlock (`codex-input-unlock`)

[English](README_EN.md) | 简体中文

针对 Windows 与 macOS 官方 Codex Desktop / ChatGPT Desktop 的**外部运行时输入解锁工具**。

当用户在客户端中配置了**第三方 API Provider**，且登录的官方账号没有额度时，官方客户端前端会强行将输入框与发送按钮置灰锁定。本项目通过 Chrome DevTools Protocol (CDP) 注入动态零暂停条件断点，**解除本地前端对输入框与发送动作的封锁**。

---

## 工作原理

```text
控制器
  ├─ Windows: PowerShell 控制器 (codex-input-unlock.ps1)
  │    ├─ 识别官方 Store 包 (Codex / ChatGPT Desktop)
  │    └─ 通过 COM 激活带调试参数的客户端
  └─ macOS: Shell 控制器 (codex-input-unlock.sh)
       ├─ 识别 /Applications (ChatGPT.app / Codex.app)
       └─ 通过 open/LaunchServices 启动带调试参数的客户端
                         │
                         ▼
CDP 守护进程 (cdp-supervisor.mjs + quota-gate.cjs)
  ├─ 连接客户端 Renderer 调试端口
  ├─ 鲁棒模式匹配定位前端 JS bundle 中的配额校验逻辑（自适应新旧版本）
  ├─ 安装条件断点：(quota = false, false)
  │    └─ 静默重置本地变量，条件恒为 false 永不挂起页面
  └─ 遇到页面刷新 (Cmd+R / Ctrl+R) 自动重新注入
```

---

## 环境要求

- **操作系统**：
  - Windows 10 / 11 (x64 / ARM64)
  - macOS 12+ (Apple Silicon / Intel)
- **官方客户端**：
  - Windows: Microsoft Store 版 Codex Desktop 或 ChatGPT Desktop
  - macOS: `/Applications/ChatGPT.app` 或 `/Applications/Codex.app`
- **运行依赖**：
  - Node.js 22+
  - Windows: PowerShell 7+ (`pwsh`)
  - macOS: Bash / Zsh (系统自带)

---

## 快速上手

### 使用前配置

启动 Codex Input Unlock 前，请先在 `~/.codex/config.toml` 中配置并确认您的第三方 Provider 可以正常使用。本项目不会代您创建、修改或校验 Provider 配置。

如果您希望在使用第三方 Provider 的同时保留 Codex 官方账号的登录状态（例如继续使用依赖登录状态的功能），请在对应 Provider 配置中设置：

```toml
requires_openai_auth = true
```

同时请先在客户端中登录您的账号。只有第三方 Provider、`requires_openai_auth = true` 和登录状态均已准备好后，本工具才负责解除官方额度状态造成的本地输入与发送门禁；它不会替代 Provider 配置或账号登录。

---

### macOS 使用指南

#### 1. 安装

在源码目录下执行：

```bash
chmod +x ./codex-input-unlock.sh
./codex-input-unlock.sh install
```

*安装会将必要运行文件复制至 `~/Library/Application Support/OpenAI/CodexInputUnlock`，并在 `~/Applications` 生成 **`Codex Input Unlock.app`** 应用程序，同时在 `~/.local/bin` 生成命令行软链接。*

#### 2. 启动

> **注意**：启动前请**完全退出**正在运行的 Codex Desktop 或 ChatGPT Desktop（通过 Cmd+Q 或菜单完全退出）。如果检测到任一客户端仍在运行，启动器不会关闭它，而会提示关闭后重试。

- **方式 A（推荐）**：使用 Spotlight (聚焦搜索) 或启动台 / 应用程序文件夹，直接打开 **`Codex Input Unlock`**。
- **方式 B（命令行）**：
  ```bash
  codex-input-unlock launch
  # 或直接执行：
  "$HOME/Library/Application Support/OpenAI/CodexInputUnlock/codex-input-unlock.sh" launch
  ```

*注：直接点击官方原生图标启动不带调试参数，不会加载解锁逻辑。*

#### 3. 验证状态

```bash
codex-input-unlock verify
```

输出中 `runtimeReady: true` 即表示守护进程正常运行、断点已挂载，输入框已解除封锁。

#### macOS 常用命令

| 命令 | 说明 |
| :--- | :--- |
| `./codex-input-unlock.sh diagnose` | 诊断环境依赖、已安装应用状态与文件完整性 |
| `./codex-input-unlock.sh launch` | 启动守护进程并唤起带调试参数的客户端 |
| `./codex-input-unlock.sh verify` | 检查守护进程存活、CDP 连通性与断点就绪状态 |
| `./codex-input-unlock.sh inspect` | 输出包含网络监听、进程与最近日志的详细诊断 JSON |
| `./codex-input-unlock.sh uninstall` | 停止守护进程、移除应用程序图标与运行目录 |

---

### Windows 使用指南

#### 1. 安装

在源码目录下打开 PowerShell 7 并执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File '.\codex-input-unlock.ps1' -Action Install
```

*安装会将必要运行文件复制至 `%LOCALAPPDATA%\OpenAI\CodexInputUnlock`，并在 Windows 开始菜单生成 **`Codex Input Unlock`** 快捷方式。*

#### 2. 启动

- **方式 A（推荐）**：打开开始菜单，直接点击 **`Codex Input Unlock`**。
- **方式 B（命令行）**：
  ```powershell
  pwsh -NoProfile -ExecutionPolicy Bypass `
    -File "$env:LOCALAPPDATA\OpenAI\CodexInputUnlock\codex-input-unlock.ps1" `
    -Action Launch
  ```

#### 3. 验证状态

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File "$env:LOCALAPPDATA\OpenAI\CodexInputUnlock\codex-input-unlock.ps1" `
  -Action Verify
```

---

## 版本自适应与升级兼容性

本工具采用**动态运行时断点**而非二进制硬修补（Hard Patch），升级 Codex 或 ChatGPT Desktop 客户端后具备高度自适应能力：

1. **动态 AST / 正则自适应**：
   - 适配不同打包工具（Vite / Rollup / Rolldown / SWC）产出的字符串字面量（单引号 `'`、双引号 `"`、模板字面量 `` ` ``）。
   - 变量声明宽松匹配（支持 `let`、`const`、`var` 以及多变量解构）。
   - 谓词链容错（即使 OpenAI 在 `||` 链中新增或调整禁用判定条件，依然能准确定位局部额度变量）。
2. **多 Candidate 动态回溯**：
   - 当 bundle 发生混淆重构时，遍历解析所有潜在的 Quota Atom 节点，精准追踪到直接挂载至 `submitDisabled` 的控制点。
3. **零暂停 CDP 条件断点**：
   - 利用 V8 调试协议的表达式副作用特性：`(quota = false, false)`。在判定时静默将额度状态设为 `false`，同时条件恒为 `false` 绝不会导致页面挂起或卡顿。
4. **前端刷新自动维护**：
   - 当遇到前端热刷新或快捷键刷新（Cmd+R / Ctrl+R）时，CDP 守护进程会自动捕获 Execution Context 变更并重新挂载断点。

---

## 测试

```bash
# macOS / Linux 静态冒烟测试
bash ./tests/smoke.sh

# Windows 静态冒烟测试
pwsh -NoProfile -ExecutionPolicy Bypass -File '.\tests\smoke.ps1' -SkipPackageCheck
```

---

## 注意事项

1. **必须通过专属入口冷启动**：官方原版快捷方式启动的进程不带 CDP 参数。
2. **仅解决本地输入框锁定**：本工具不伪造服务端 API 额度；第三方 API 的调用消耗、鉴权和限流由您配置的 Provider 自行处理。
3. **安全与零篡改保证**：本工具遵循只读原则，**绝不擅自修改用户的 `config.toml` 配置文件**。
4. **免责声明**：本项目为独立的非官方开源工具，与 OpenAI 无任何隶属关系。

---

## License

[MIT](LICENSE)

[LINUX DO](https://linux.do)
