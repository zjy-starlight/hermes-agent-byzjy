# Hermes Agent — 中文说明

面向本地开发与使用的精简说明：目录结构、配置位置、核心调用链。

---

## 一、项目目录结构

```
hermes-agent/
├── run_agent.py          # AIAgent：对话循环、模型调用、工具调用
├── model_tools.py        # 工具编排、handle_function_call()
├── toolsets.py           # 工具集定义、核心工具列表
├── cli.py                # HermesCLI：经典交互终端
├── hermes_state.py       # SessionDB：SQLite 会话与 FTS5 搜索
├── hermes_constants.py   # HERMES_HOME 等共享常量
│
├── agent/                # Agent 内部
│   ├── prompt_builder.py      # 系统提示拼装
│   ├── context_compressor.py  # 上下文压缩
│   ├── auxiliary_client.py    # 辅助模型（视觉、摘要等）
│   ├── model_metadata.py      # 上下文长度、token 估算
│   ├── display.py             # 终端 spinner、工具输出样式
│   ├── skill_commands.py      # 技能 slash（CLI / 网关共用）
│   └── …
│
├── hermes_cli/           # `hermes` 命令与子命令
│   ├── main.py           # 入口：profile、.env、再调 cli.py
│   ├── config.py         # 默认配置、环境变量元数据、迁移
│   ├── auth.py           # 各厂商凭证解析
│   ├── commands.py       # Slash 命令注册表
│   ├── model_switch.py   # /model 等切换流水线
│   └── …
│
├── tools/                # 工具实现（按文件注册到 registry）
│   ├── registry.py       # 工具注册与分发（无业务依赖，最先被 import）
│   ├── file_tools.py     # read_file / write_file / patch / search_files
│   ├── terminal_tool.py  # 终端执行
│   ├── approval.py       # 危险命令审批
│   ├── mcp_tool.py       # MCP 客户端
│   └── environments/   # 终端后端：local、docker、ssh 等
│
├── gateway/              # 消息网关（Telegram、Discord、Slack 等）
├── ui-tui/               # `hermes --tui`：Ink 前端
├── tui_gateway/          # TUI 的 Python JSON-RPC 后端
├── acp_adapter/          # 编辑器 ACP 集成
├── cron/                 # 定时任务
├── environments/         # RL 等训练环境（与 tools/environments 不同）
├── tests/                # Pytest
├── scripts/              # 安装、一键启动等脚本
├── batch_runner.py       # 批量并行
└── pyproject.toml        # 包定义；入口 hermes → hermes_cli.main:main
```

**依赖链（理解 import 顺序）：**

`tools/registry.py` → 各 `tools/*.py` 注册 → `model_tools.py` → `run_agent.py` / `cli.py` / `gateway` 等。

---

## 二、用户配置放哪

| 用途 | 路径 |
|------|------|
| 主配置 | `{HERMES_HOME}/config.yaml`，默认 `~/.hermes/config.yaml` |
| 密钥与环境 | `{HERMES_HOME}/.env` |
| 根目录 | 由环境变量 **`HERMES_HOME`** 决定；未设置时为 **`%USERPROFILE%\.hermes`**（小写 `.hermes`） |

多实例可用 **profile**：`hermes -p <name>`，此时 `HERMES_HOME` 会指到 `~/.hermes/profiles/<name>`（详见仓库 `AGENTS.md` 中 Profiles 一节）。

---

## 三、怎么启动

- **推荐**：安装后执行 **`hermes`**（会走 `hermes_cli/main.py`，含 profile、早期配置等）。
- **开发**：也可在项目根执行 **`python cli.py`**，但 profile 预解析以 `hermes` 为准。

Windows 下一键启动可参考仓库内 **`scripts/start-hermes.ps1`**（可按需设置 `HERMES_GIT_BASH_PATH`、Ollama 预检等）。

---

## 四、与本机相关的注意点（Windows）

1. **终端后端**：本地文件类工具常通过 **Git Bash** 执行 POSIX 命令；请安装 **Git for Windows**，并可用 **`HERMES_GIT_BASH_PATH`** 指向 `...\Git\bin\bash.exe`，避免误用系统里的 WSL `bash.exe` 导致路径（如 `/d` vs `/mnt/d`）不一致。
2. **盘符路径**：在 Bash 侧写 **`/d/...`、`/c/...`** 往往比混用 `D:\` 更稳；口语「D 盘」对应 **`/d/`**。
3. **本地 Ollama**：在 `config.yaml` 的 `model` 里配置 **`provider: custom`**、**`base_url: http://localhost:11434/v1`**、模型名；小上下文模型可能需 **`model.context_length`** 等覆盖（见官方 FAQ / `AGENTS.md`）。

---

## 五、更多文档

- 开发与贡献细节：**`AGENTS.md`**（英文，最全）。
- 用户向导与集成：**`website/docs/`** 或线上文档站点。

本文仅作中文速览；与 `AGENTS.md` 冲突时以仓库内最新 **`AGENTS.md`** 为准。
