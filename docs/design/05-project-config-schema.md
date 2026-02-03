# TidyFlow - 项目配置 Schema (Project Config Schema)

> 版本: 1.0 (Frozen)
> 最后更新: 2026-01-31

## 配置文件概述

**文件名**: `.tidyflow.toml`
**位置**: 项目根目录
**格式**: TOML

配置文件用于定义项目级别的设置，包括 setup 脚本、环境变量、忽略规则等。

---

## Schema 定义

### 顶层结构

```toml
# .tidyflow.toml

# 项目元信息 (可选)
[project]
name = "my-project"           # 显示名称，默认使用目录名
description = "..."           # 项目描述

# Setup 配置 (可选)
[setup]
# ... setup 相关配置

# 环境变量 (可选)
[env]
# ... 环境变量配置

# 忽略规则 (可选)
[ignore]
# ... 忽略配置

# 同步/更新配置 (可选)
[sync]
# ... 同步配置
```

---

### [project] 节

项目元信息配置。

| 字段 | 类型 | 必选 | 默认值 | 说明 |
|------|------|------|--------|------|
| `name` | string | 否 | 目录名 | 项目显示名称 |
| `description` | string | 否 | "" | 项目描述 |
| `default_branch` | string | 否 | "main" | 默认分支名 |

```toml
[project]
name = "TidyFlow"
description = "Multi-project development tool for macOS"
default_branch = "main"
```

---

### [setup] 节

Workspace 初始化时执行的脚本配置。

| 字段 | 类型 | 必选 | 默认值 | 说明 |
|------|------|------|--------|------|
| `timeout` | integer | 否 | 600 | 总超时时间 (秒) |
| `shell` | string | 否 | 系统默认 | 执行脚本的 shell |
| `working_dir` | string | 否 | worktree root | 工作目录 |
| `steps` | array | 否 | [] | 执行步骤列表 |

#### Setup Step 结构

| 字段 | 类型 | 必选 | 默认值 | 说明 |
|------|------|------|--------|------|
| `name` | string | 是 | - | 步骤名称 (用于显示) |
| `run` | string | 是 | - | 执行的命令 |
| `timeout` | integer | 否 | 继承 setup.timeout | 单步超时 (秒) |
| `continue_on_error` | boolean | 否 | false | 失败是否继续 |
| `condition` | string | 否 | - | 执行条件 |
| `env` | table | 否 | {} | 步骤级环境变量 |
| `working_dir` | string | 否 | 继承 setup.working_dir | 步骤工作目录 |

#### 条件表达式 (condition)

| 表达式 | 说明 | 示例 |
|--------|------|------|
| `file_exists:<path>` | 文件存在时执行 | `file_exists:package.json` |
| `file_not_exists:<path>` | 文件不存在时执行 | `file_not_exists:node_modules` |
| `dir_exists:<path>` | 目录存在时执行 | `dir_exists:vendor` |
| `env_set:<var>` | 环境变量已设置时执行 | `env_set:CI` |
| `env_not_set:<var>` | 环境变量未设置时执行 | `env_not_set:SKIP_INSTALL` |
| `command_exists:<cmd>` | 命令存在时执行 | `command_exists:cargo` |

```toml
[setup]
timeout = 300
shell = "/bin/zsh"

[[setup.steps]]
name = "Install Node dependencies"
run = "npm install"
timeout = 120
condition = "file_exists:package.json"

[[setup.steps]]
name = "Install Python dependencies"
run = "pip install -r requirements.txt"
condition = "file_exists:requirements.txt"
continue_on_error = true

[[setup.steps]]
name = "Build project"
run = "npm run build"
condition = "file_exists:package.json"
env = { NODE_ENV = "development" }
```

---

### [env] 节

环境变量配置，会注入到所有终端和 setup 脚本中。

| 字段 | 类型 | 必选 | 默认值 | 说明 |
|------|------|------|--------|------|
| `inherit` | boolean | 否 | true | 是否继承系统环境变量 |
| `vars` | table | 否 | {} | 自定义环境变量 |
| `path_prepend` | array | 否 | [] | 添加到 PATH 前面的路径 |
| `path_append` | array | 否 | [] | 添加到 PATH 后面的路径 |

```toml
[env]
inherit = true

[env.vars]
NODE_ENV = "development"
DEBUG = "app:*"
DATABASE_URL = "postgres://localhost/dev"

[env.path_prepend]
paths = ["./node_modules/.bin", "./bin"]

[env.path_append]
paths = ["/usr/local/custom/bin"]
```

---

### [ignore] 节

文件/目录忽略规则，用于文件监听和 git 状态显示。

| 字段 | 类型 | 必选 | 默认值 | 说明 |
|------|------|------|--------|------|
| `patterns` | array | 否 | [] | 忽略的 glob 模式 |
| `use_gitignore` | boolean | 否 | true | 是否使用 .gitignore |
| `use_global_gitignore` | boolean | 否 | true | 是否使用全局 gitignore |

```toml
[ignore]
use_gitignore = true
use_global_gitignore = true
patterns = [
  "*.log",
  "*.tmp",
  ".DS_Store",
  "node_modules/",
  "target/",
  "dist/",
  ".cache/",
]
```

---

### [sync] 节

同步/更新配置，定义如何保持 workspace 与远程同步。

| 字段 | 类型 | 必选 | 默认值 | 说明 |
|------|------|------|--------|------|
| `auto_fetch` | boolean | 否 | true | 是否自动 fetch |
| `fetch_interval` | integer | 否 | 300 | 自动 fetch 间隔 (秒) |
| `notify_behind` | boolean | 否 | true | 落后时是否通知 |
| `update_command` | string | 否 | - | 自定义更新命令 |

```toml
[sync]
auto_fetch = true
fetch_interval = 300
notify_behind = true
update_command = "git pull --rebase && npm install"
```

---

### [terminal] 节 (可选)

终端默认配置。

| 字段 | 类型 | 必选 | 默认值 | 说明 |
|------|------|------|--------|------|
| `shell` | string | 否 | 系统默认 | 默认 shell |
| `font_size` | integer | 否 | 14 | 字体大小 |
| `font_family` | string | 否 | "Menlo" | 字体 |
| `scrollback` | integer | 否 | 10000 | 回滚行数 |

```toml
[terminal]
shell = "/bin/zsh"
font_size = 14
font_family = "JetBrains Mono"
scrollback = 10000
```

---

### [editor] 节 (可选)

编辑器配置。

| 字段 | 类型 | 必选 | 默认值 | 说明 |
|------|------|------|--------|------|
| `external` | string | 否 | - | 外部编辑器命令 |
| `open_command` | string | 否 | - | 打开文件命令模板 |

```toml
[editor]
external = "code"
open_command = "code -g {file}:{line}:{column}"
```

---

## 完整示例配置

```toml
# .tidyflow.toml
# TidyFlow 项目配置文件

[project]
name = "my-fullstack-app"
description = "A full-stack web application"
default_branch = "main"

[setup]
timeout = 600
shell = "/bin/zsh"

[[setup.steps]]
name = "Check Node.js version"
run = "node --version"
continue_on_error = true

[[setup.steps]]
name = "Install Node dependencies"
run = "npm ci"
timeout = 180
condition = "file_exists:package.json"

[[setup.steps]]
name = "Install Python dependencies"
run = "pip install -r requirements.txt"
timeout = 120
condition = "file_exists:requirements.txt"

[[setup.steps]]
name = "Setup database"
run = "npm run db:migrate"
condition = "file_exists:prisma/schema.prisma"
env = { DATABASE_URL = "postgres://localhost/dev" }

[[setup.steps]]
name = "Build frontend"
run = "npm run build:dev"
condition = "file_exists:package.json"
continue_on_error = true

[[setup.steps]]
name = "Generate types"
run = "npm run generate:types"
condition = "file_exists:package.json"
continue_on_error = true

[env]
inherit = true

[env.vars]
NODE_ENV = "development"
DEBUG = "app:*"
LOG_LEVEL = "debug"

[env.path_prepend]
paths = ["./node_modules/.bin", "./scripts"]

[ignore]
use_gitignore = true
patterns = [
  "*.log",
  ".DS_Store",
  "coverage/",
  ".nyc_output/",
]

[sync]
auto_fetch = true
fetch_interval = 300
notify_behind = true
update_command = "git pull --rebase && npm ci"

[terminal]
shell = "/bin/zsh"
font_size = 14
scrollback = 10000

[editor]
external = "cursor"
open_command = "cursor -g {file}:{line}:{column}"
```

---

## 配置加载优先级

配置按以下优先级合并（后者覆盖前者）：

1. **内置默认值** - TidyFlow 硬编码的默认配置
2. **全局配置** - `~/.config/tidyflow/config.toml`
3. **项目配置** - `<project>/.tidyflow.toml`
4. **Workspace 覆盖** - 运行时通过 API 设置的覆盖值

---

## 配置验证

### 验证规则

| 规则 | 说明 |
|------|------|
| timeout > 0 | 超时必须为正数 |
| shell 路径存在 | shell 必须是有效的可执行文件 |
| step.name 非空 | 步骤名称不能为空 |
| step.run 非空 | 步骤命令不能为空 |
| condition 格式正确 | 条件表达式必须符合规定格式 |

### 验证时机

- 项目导入时
- 配置文件修改时（文件监听）
- Workspace 创建前

### 验证失败处理

- 显示详细错误信息（行号、字段）
- 提供修复建议
- 允许使用默认配置继续（警告模式）

---

## 配置迁移

### 从其他工具迁移

| 来源 | 迁移方式 |
|------|----------|
| `.nvmrc` | 自动检测，添加 nvm use 到 setup |
| `.node-version` | 同上 |
| `.python-version` | 自动检测，添加 pyenv 到 setup |
| `Makefile` | 提示用户手动配置 |
| `docker-compose.yml` | 提示用户手动配置 |

### 自动检测

TidyFlow 会自动检测常见项目类型并生成建议配置：

| 检测文件 | 建议 setup |
|----------|-----------|
| `package.json` | `npm install` |
| `package-lock.json` | `npm ci` |
| `yarn.lock` | `yarn install` |
| `pnpm-lock.yaml` | `pnpm install` |
| `requirements.txt` | `pip install -r requirements.txt` |
| `Cargo.toml` | `cargo build` |
| `go.mod` | `go mod download` |
| `Gemfile` | `bundle install` |
