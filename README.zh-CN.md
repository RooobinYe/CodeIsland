<h1 align="center">
  <img src="logo.png" width="56" height="56" alt="CodeIsland logo" valign="middle">&nbsp;
  CodeIsland
</h1>

<p align="center">
  <b>把你的 AI 编码 Agent 装进 MacBook 刘海。</b><br>
  哪个 Agent 在运行、哪个在等你、哪个刚跑完，一眼看清，不用离开当前窗口。
</p>

<p align="center">
  <a href="https://github.com/wxtsky/CodeIsland/releases/latest"><img src="https://img.shields.io/github/v/release/wxtsky/CodeIsland?style=flat-square&color=4c8bf5&label=release" alt="最新版本"></a>
  <a href="https://github.com/wxtsky/CodeIsland/releases"><img src="https://img.shields.io/github/downloads/wxtsky/CodeIsland/total?style=flat-square&color=2ea44f" alt="下载量"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-111111?style=flat-square&logo=apple&logoColor=white" alt="macOS 14+">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/wxtsky/CodeIsland?style=flat-square&color=8250df" alt="MIT 许可证"></a>
  <a href="https://github.com/wxtsky/CodeIsland/stargazers"><img src="https://img.shields.io/github/stars/wxtsky/CodeIsland?style=flat-square&color=e3b341" alt="GitHub stars"></a>
</p>

<p align="center">
  <a href="#安装">安装</a> •
  <a href="#亮点">亮点</a> •
  <a href="#支持的工具">支持的工具</a> •
  <a href="#工作原理">工作原理</a> •
  <a href="#从源码构建">构建</a>
  <br>
  <a href="README.md">English</a> | <b>简体中文</b>
</p>

<p align="center">
  <img src="docs/images/readme-hero-zh.png" width="760" alt="从 MacBook 刘海展开的 CodeIsland，显示 Claude Code、Codex、Cursor 和 Gemini CLI 的会话">
</p>

## 为什么需要 CodeIsland？

编码 Agent 大部分时间不是在干活，就是在等你——而你只有切到它的窗口才知道是哪种。CodeIsland 把刘海变成所有 Agent 的实时状态栏：哪个会话在运行、哪个阻塞在审批或提问上、哪个刚跑完，一目了然。刘海只负责展示：审批和提问都在 Agent 自己那里处理，点一下即可跳到对应的终端标签页。

> 这是一个仅供个人使用、只做展示的 fork：刘海上没有审批和答题，没有 Buddy 配套设备，没有吉祥物动画，也没有自动更新。

支持 **30+ 款 AI 编码工具**，hook 自动安装，所有数据留在你的 Mac 上。

## 亮点

<table>
<tr>
<td width="50%" valign="top">

**👀 一眼看清全部**

- 每个会话的状态、当前工具和最新回复，实时更新；完成的回复按 Markdown 渲染（列表、表格、代码块）
- 可选在会话卡片上显示模型与推理强度
- 卡片上显示 Git 分支与 worktree
- 每个工具一个静态 logo，一眼分清是哪种 harness

</td>
<td width="50%" valign="top">

**🚦 运行中、阻塞中、已完成**

- 每个会话都显示它在运行、阻塞在你身上（审批或提问），还是已经完成
- 刘海从不扣住请求：Agent 照常在自己的界面里询问，就像没装 CodeIsland 一样
- 一键跳到对应的终端标签页、IDE 窗口，或 tmux / zellij / Herdr 面板
- 全局快捷键：开关面板、跳转到终端

</td>
</tr>
<tr>
<td width="50%" valign="top">

**🧘 不打扰你**

- 智能抑制：你正盯着那个会话的标签页时不提醒
- 静默时段、按事件的 8-bit 音效、「小圆点」完成提示模式
- 全屏时自动隐藏、自动避让菜单栏图标
- 静默规则：指定目录的会话永不打扰
- 锁屏、屏保、显示器睡眠时自动静音；单个工具失败不再响错误音，只有整轮失败才响
- 可选的跟进提醒：阻塞中的会话和你还没看的完成结果，过几分钟再提醒一次

</td>
<td width="50%" valign="top">

**🌐 不止这台 Mac**

- SSH 远程主机：服务器上的会话和本地会话并排显示
- 推送到手机或群聊：Bark、ntfy、钉钉、飞书、企业微信、Slack、Telegram，默认只在你离开时推
- Webhook 转发原始事件，方便接自己的自动化
- 7 种界面语言

</td>
</tr>
</table>


## 支持的工具

<table>
<tr>
<td align="center" width="16%"><img src="Sources/CodeIsland/Resources/cli-icons/claude.png" width="48" alt=""><br><sub><b>Claude Code</b></sub></td>
<td align="center" width="16%"><img src="Sources/CodeIsland/Resources/cli-icons/codex.png" width="48" alt=""><br><sub><b>Codex</b></sub></td>
<td align="center" width="16%"><img src="Sources/CodeIsland/Resources/cli-icons/gemini.png" width="48" alt=""><br><sub><b>Gemini CLI</b></sub></td>
<td align="center" width="16%"><img src="Sources/CodeIsland/Resources/cli-icons/cursor.png" width="48" alt=""><br><sub><b>Cursor</b></sub></td>
<td align="center" width="16%"><img src="Sources/CodeIsland/Resources/cli-icons/grok.png" width="48" alt=""><br><sub><b>Grok CLI</b></sub></td>
<td align="center" width="16%"><img src="Sources/CodeIsland/Resources/cli-icons/opencode.png" width="48" alt=""><br><sub><b>OpenCode</b></sub></td>
</tr>
<tr>
<td align="center"><img src="Sources/CodeIsland/Resources/cli-icons/qoder.png" width="48" alt=""><br><sub><b>Qoder</b></sub></td>
<td align="center"><img src="Sources/CodeIsland/Resources/cli-icons/trae.png" width="48" alt=""><br><sub><b>Trae</b></sub></td>
<td align="center"><img src="Sources/CodeIsland/Resources/cli-icons/copilot.png" width="48" alt=""><br><sub><b>Copilot CLI</b></sub></td>
<td align="center"><img src="Sources/CodeIsland/Resources/cli-icons/factory.png" width="48" alt=""><br><sub><b>Factory Droid</b></sub></td>
<td align="center"><img src="Sources/CodeIsland/Resources/cli-icons/codebuddy.png" width="48" alt=""><br><sub><b>CodeBuddy</b></sub></td>
<td align="center"><img src="Sources/CodeIsland/Resources/cli-icons/qwen.png" width="48" alt=""><br><sub><b>Qwen Code</b></sub></td>
</tr>
<tr>
<td align="center"><img src="Sources/CodeIsland/Resources/cli-icons/kimi.png" width="48" alt=""><br><sub><b>Kimi Code CLI</b></sub></td>
<td align="center"><img src="Sources/CodeIsland/Resources/cli-icons/cline.png" width="48" alt=""><br><sub><b>Cline</b></sub></td>
<td align="center"><img src="Sources/CodeIsland/Resources/cli-icons/pi.png" width="48" alt=""><br><sub><b>Pi / Oh My Pi</b></sub></td>
<td align="center"><img src="Sources/CodeIsland/Resources/cli-icons/hermes.png" width="48" alt=""><br><sub><b>Hermes</b></sub></td>
<td align="center"><img src="Sources/CodeIsland/Resources/cli-icons/openclaw.png" width="48" alt=""><br><sub><b>OpenClaw</b></sub></td>
<td align="center"><img src="Sources/CodeIsland/Resources/cli-icons/antigravity.png" width="40" alt=""><br><sub><b>Google Antigravity</b></sub></td>
</tr>
<tr>
<td align="center"><img src="Sources/CodeIsland/Resources/cli-icons/kiro.png" width="48" alt=""><br><sub><b>Kiro CLI</b></sub></td>
<td align="center"><img src="Sources/CodeIsland/Resources/cli-icons/stepfun.png" width="48" alt=""><br><sub><b>StepFun</b></sub></td>
<td align="center"><img src="Sources/CodeIsland/Resources/cli-icons/workbuddy.png" width="48" alt=""><br><sub><b>WorkBuddy</b></sub></td>
<td align="center"><img src="Sources/CodeIsland/Resources/cli-icons/minimax.png" width="40" alt=""><br><sub><b>MiniMax Code CLI</b></sub></td>
<td align="center"><img src="Sources/CodeIsland/Resources/cli-icons/dsh.png" width="40" alt=""><br><sub><b>DeepSeek Harness</b></sub></td>
<td align="center"><img src="Sources/CodeIsland/Resources/cli-icons/aiwork.png" width="48" alt=""><br><sub><b>AiWork</b></sub></td>
</tr>
<tr>
<td align="center"><img src="Sources/CodeIsland/Resources/cli-icons/mimo.png" width="48" alt=""><br><sub><b>MiMo Code /<br>Xiaomi MiMo</b></sub></td>
<td align="center"><sub><b>+ 更多</b><br>见下方 ↓</sub></td>
</tr>
</table>

**同样支持：** Trae CN、Trae CLI / Trae CLI Next、Qoder CN、Qoder App、QoderWork 与 Qoder CLI、Cursor CLI、CodeBuddy CN、Claude Desktop（Code 标签页与 [Cowork](#cowork)）、ZCode。其他使用 Claude 风格 hook 的工具，可以在 设置 → Hooks 里添加为**自定义 CLI**。

**多个账号？** 在 **设置 → Hooks** 里登记额外的 Claude Code、Codex、Grok 配置目录（比如第二个 `CLAUDE_CONFIG_DIR`），每个目录单独安装 hook、单独显示状态，会话、transcript 和用量统计都会覆盖到。

**知道它跑在哪：** 运行在 **tmux**、**zellij**、**Herdr** 或 **T3 Code** 里的会话，终端徽标旁会多一个标签，点击跳转会直达对应的面板或线程。

**审批与提问：** 只展示、不处理。等待权限确认或提问的会话会标记为阻塞中，你在 Agent 自己的界面里作答。

<details>
<summary><b>各集成安装在哪里</b></summary>

<br>

CodeIsland 启动时会自动写入以下配置，配置被改动时会自动修复；每一项都可以在 **设置 → Hooks** 里单独关闭。

| 工具 | 安装位置 |
|------|----------|
| Claude Code | 插件 `~/.claude/skills/codeisland/`，需要 2.1.157 及以上（遵循 `$CLAUDE_CONFIG_DIR`） |
| Codex | `~/.codex/hooks.json`，[需要审核一次](#codex) |
| Gemini CLI | `~/.gemini/settings.json` |
| Google Antigravity | `~/.gemini/config/hooks.json` |
| Cursor / Cursor CLI | `~/.cursor/hooks.json` |
| Grok CLI | `~/.grok/hooks/codeisland.json` |
| Qoder（IDE 与 Qoder App）/ Qoder CN / QoderWork | `~/.qoder/`、`~/.qoder-cn/`、`~/.qoderwork/` 下的 `settings.json` |
| Trae / Trae CN | `~/.trae/hooks.json`、`~/.trae-cn/hooks.json`（需在 Trae 里打开全局 Hook） |
| Trae CLI / Trae CLI Next | `~/.trae/traecli.yaml`、`~/.trae/cli/hooks.json` |
| Factory、CodeBuddy、StepFun、WorkBuddy、Qwen Code | `~/.<工具>/settings.json` |
| Copilot CLI | `~/.copilot/hooks/codeisland.json` |
| Kimi Code CLI | `~/.kimi-code/config.toml`（旧版为 `~/.kimi/`） |
| Kiro CLI | `~/.kiro/agents/codeisland.json`，需用 `kiro --agent codeisland` 启动 |
| Hermes | `~/.hermes/config.yaml`，[需要批准一次](#hermes) |
| ZCode | `~/.zcode/cli/config.json` |
| MiniMax Code CLI | 插件 `~/.minimax/plugins/codeisland/`（支持 `$MINIMAX_DATA_DIR`） |
| Cline | `~/Documents/Cline/Hooks` |
| OpenCode | 插件 `~/.config/opencode/plugins/codeisland.js` |
| MiMo Code / Xiaomi MiMo | 插件 `~/.config/mimocode/plugins/codeisland.js`，见[下文](#mimo) |
| Pi / Oh My Pi | 扩展 `~/.pi/agent/extensions/pi-codeisland/` / `~/.omp/agent/extensions/codeisland.ts` |
| OpenClaw | 插件 `~/.openclaw/codeisland-plugin/` |
| DeepSeek Harness | [dsh-island](https://github.com/cdxiaodong/dsh-island) 插件，见[下文](#deepseek-harness) |
| AiWork | 无需安装，直接读取 AiWork 本机守护进程 |

</details>

## 安装

这个 fork 不提供预编译版本，也不会自动更新。请从源码构建（见[从源码构建](#从源码构建)），把 `.build/release/CodeIsland.app` 拷到「应用程序」；启动时会自动为检测到的每个 AI 工具安装 hook。

## 配置说明

<a name="codex"></a>
<details>
<summary><b>Codex：首次需要信任 hook</b></summary>

<br>

Codex 不会执行没审核过的 hook。安装后启动 Codex，它会提示 `1 hook needs review before it can run.`，运行 `/hooks`，审核并信任 CodeIsland 的条目即可。审核之前 Codex 会静默忽略这些 hook，不报任何错，看起来就像 CodeIsland 不支持 Codex。Codex 会在 `~/.codex/config.toml` 的 `[hooks.state]` 里为每个已信任的 hook 记录内容哈希，所以 CodeIsland 更新后如果改写了 `~/.codex/hooks.json`，需要再审核一次。

Codex 自动审查（Auto Review）仍由 Codex 处理。某一轮使用自动审查时，权限请求由 Codex 的审查方决定，会话不会显示为阻塞中。审查方取自本地 rollout 中该轮的 `turn_context`，因此在 Codex 桌面端权限菜单里的选择同样生效；读不到时再看 `config.toml` 里的 `approvals_reviewer`。

Codex 回合进行中、且没有工具在运行时，收起状态的刘海会显示 Agent 最新的公开输出。隐藏推理、加密内容、工具结果和内部子 Agent 消息永远不会显示。

</details>

<details>
<summary><b>OpenCode 1.x 与 2</b></summary>

<br>

OpenCode 通过一个 JS 插件直连 socket，不需要 bridge 程序。同一个插件文件同时支持 OpenCode 1.x（`server()`）和 OpenCode 2（`setup()`），OpenCode 2 会从 `~/.config/opencode/plugins/` 自动加载它。在 OpenCode 2 的共享后台服务模式下，点击跳转只能定位到终端 App、到不了具体标签页；提问通过该服务的本机 HTTP 接口回答。

</details>

<a name="mimo"></a>
<details>
<summary><b>MiMo Code 与 Xiaomi MiMo 桌面端</b></summary>

<br>

MiMo Code 是 OpenCode 1.x 的分支，Xiaomi MiMo 桌面端又以 MiMo Code 作为内核，所以两者都会从 `~/.config/mimocode/plugins/` 加载 OpenCode 插件。CodeIsland 把插件以 MiMo 的身份写到这里，不改动 `mimocode.json`。MiMo 只在内核启动时读取插件，插件装好后需要重启一次 App（或 `mimo`）。审批和提问可以在刘海上处理，也可以在 MiMo 里处理，以先操作的一方为准。点击桌面端会话会把 Xiaomi MiMo 切到前台；它的 `xiaomi-mimo://` 链接只用于加入分享的会话，没办法直接打开某个对话。

</details>

<a name="hermes"></a>
<details>
<summary><b>Hermes：首次需要批准 hook</b></summary>

<br>

Hermes 遇到没见过的 hook 会先询问，每个 hook 问一次。下次在终端启动 `hermes` 时，对 CodeIsland 的条目（`codeisland-bridge --source hermes`；SSH 远程主机上是 `codeisland-remote-hook.py` 那些）逐个回答 `y` 即可。没有终端的 Hermes（gateway 服务、桌面 App）无法询问，会直接跳过没批准的 hook，看起来就像 CodeIsland 看不到这些会话。在终端里批准一次即可（批准记录按 Hermes 主目录保存，gateway 和桌面 App 同样生效），或者在 `~/.hermes/config.yaml` 里设置 `hooks_auto_accept: true`。CodeIsland 更新后如果新增了 hook，Hermes 会就新的 hook 再问一次。

Gateway 聊天（Telegram、Discord、Slack、WhatsApp、邮件等，以及 API Server）也会显示卡片，但不弹完成卡片、不响提示音，空闲 10 分钟后移除。会话结束时卡片随之移除：`/new`、退出 `hermes`、关闭桌面端对话，或 gateway 停止。会话标题只读地取自 Hermes 自己的 `state.db`。

</details>

<a name="deepseek-harness"></a>
<details>
<summary><b>DeepSeek Harness</b></summary>

<br>

DSH 原生支持插件，CodeIsland 不需要安装任何 hook。[dsh-island](https://github.com/cdxiaodong/dsh-island) 插件会监听 DSH 的内置事件并写入 CodeIsland 的 socket：

```bash
dsh plugin --profile <profile> add github:cdxiaodong/dsh-island
```

</details>

<details>
<summary><b>Google Antigravity</b></summary>

<br>

Antigravity 的 `PreToolUse` hook 只能拒绝工具调用、不能批准，所以刘海对 Antigravity 只做**观察**：显示正在运行的工具，每一次决定都交还给 Antigravity 自己的权限弹窗，你设置的授权和「始终允许」照常生效。

</details>

<details>
<summary><b>SSH 远程主机</b></summary>

<br>

在 **设置 → 远程** 添加主机。CodeIsland 会在服务器上安装一个小助手和 hook（合并进你现有的配置，不会覆盖），并通过 SSH 把事件转发回来。可选的「工作目录过滤」能在共享服务器上挡掉别人的会话。某个工具显示 `skipped` 时，状态行会写明原因，通常是那台主机上还没有它的配置目录。

</details>

<a name="cowork"></a>
<details>
<summary><b>Claude Desktop Cowork</b></summary>

<br>

Cowork 跑在 Claude Desktop 的沙盒里，hook 不会触发，所以 CodeIsland 改为读取 Claude Desktop 保存在你 Mac 上的会话文件（`~/Library/Application Support/Claude/local-agent-mode-sessions/`，只读，不在那里安装或写入任何东西）。Cowork 对话会有自己的卡片：标题、实时状态、正在运行的工具、最新回复和完成提示音；有待处理的权限请求时显示为等待中。审批仍在 Claude Desktop 里完成，点击卡片会打开对应的对话。只显示最近几分钟内活跃的会话，旧会话不会变成幽灵卡片。开关在 **设置 → Hooks → Claude Desktop**。

</details>

<a name="push"></a>
<details>
<summary><b>推送到手机和群聊</b></summary>

<br>

**设置 → 行为 → 推送通知** 可以把阻塞中的会话（它在等的审批或提问，附编号选项）、完成、整轮出错和跟进提醒推送到 Bark、ntfy、钉钉、飞书 / Lark、企业微信、Slack 或 Telegram。可以同时启用多个通道，每个通道单独选择推送哪些事件，「发送测试」按钮会显示服务端的真实返回。默认只在你离开时推送（锁屏、屏保、显示器睡眠，或键盘鼠标 5 分钟没有操作），子 Agent 的回合不推送。命令和消息会经过和应用其他部分相同的凭据脱敏。推送只负责通知，审批和提问仍在 Agent 里处理。

</details>

## 工作原理

```
AI 工具（Claude Code / Codex / Gemini / Cursor / …）
  └─ 触发 hook ─→ codeisland-bridge（原生 Swift 小程序）
                    └─ Unix socket /tmp/codeisland-<uid>.sock
                         └─ CodeIsland 实时更新刘海
                              └─ 可选：推送、Webhook
```

CodeIsland 往每个工具自己的配置里装一个轻量 hook。工具触发事件时（会话开始、工具调用、权限请求、提问、结束），bridge 把事件以 JSON 形式经本机 Unix socket 转发过来，刘海立即更新。bridge 从不等待决定，Agent 始终在自己的界面里询问。

**隐私：** 除非你主动开启，事件不会离开你的 Mac。CodeIsland 默认不发出任何网络请求，只有在你打开时才会有：发往你所配置地址的 Webhook 转发，以及发往你所配置服务的推送。

## 设置

| 页面 | 内容 |
|------|------|
| **通用** | 语言、开机启动、显示器选择 |
| **行为** | 智能抑制、完成提示方式、跟进提醒、会话清理、静默规则、推送通知、Webhook |
| **外观** | 面板尺寸、刘海宽度、字号、回复行数、项目名、Git 分支、模型标签 |
| **声音** | 按事件的 8-bit 音效、音量、静默时段、离开时自动静音 |
| **快捷键** | 全局快捷键：开关面板、跳转 |
| **远程** | SSH 主机及每台主机的目录过滤 |
| **Hooks** | 各工具安装状态、重新安装 / 卸载、额外配置目录、Claude Desktop Cowork、自定义 CLI |
| **关于** | 版本、本版本更新说明、导出诊断信息 |

### 键盘快捷键

| 快捷键 | 功能 | 默认 |
|--------|------|------|
| <kbd>⌘</kbd><kbd>⇧</kbd><kbd>I</kbd> | 展开 / 收起灵动岛 | 开启 |

所有快捷键都可以在 **设置 → 快捷键** 里改绑，还能给「跳转到终端」绑定快捷键。

## 从源码构建

需要 **macOS 14+** 和 **Swift 5.9+**。

```bash
git clone https://github.com/wxtsky/CodeIsland.git
cd CodeIsland

# 开发：debug 构建并启动
swift build && ./.build/debug/CodeIsland

# 发布：通用二进制（Apple Silicon + Intel）
./build.sh
open .build/release/CodeIsland.app

# 测试
swift test
```

## 系统要求

- macOS 14 Sonoma 或更高版本
- 带刘海的 MacBook 体验最佳；外接显示器和无刘海屏幕也能用

## 致谢

灵感来自 [@farouqaldori](https://github.com/farouqaldori) 的 [claude-island](https://github.com/farouqaldori/claude-island)，感谢把 AI Agent 状态放进 macOS 刘海这个最初的想法。也感谢所有贡献集成、修复和问题反馈的朋友。

## Star History

<a href="https://star-history.dera.page/#wxtsky/CodeIsland&type=date&legend=bottom-right">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://star-history.dera.page/svg?repos=wxtsky/CodeIsland&type=date&theme=dark&legend=top-left" />
    <source media="(prefers-color-scheme: light)" srcset="https://star-history.dera.page/svg?repos=wxtsky/CodeIsland&type=date&legend=top-left" />
    <img alt="Star History 图表" src="https://star-history.dera.page/svg?repos=wxtsky/CodeIsland&type=date&legend=top-left" />
  </picture>
</a>

## 许可证

MIT，详见 [LICENSE](LICENSE)。
