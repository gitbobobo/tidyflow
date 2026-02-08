<p align="center">
  <img src="design/tidyflow_icon.svg" width="128" height="128" alt="TidyFlow Logo">
</p>

<h1 align="center">TidyFlow</h1>

<p align="center">
  <strong>Flow with Grace</strong><br/>
  A multi-project parallel development tool for the AI era
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-LGPL--3.0-blue.svg" alt="License"></a>
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/Platform-macOS-black.svg" alt="Platform"></a>
  <a href="https://www.rust-lang.org/"><img src="https://img.shields.io/badge/Language-Rust-orange.svg" alt="Rust"></a>
  <a href="https://developer.apple.com/xcode/swiftui/"><img src="https://img.shields.io/badge/UI-SwiftUI-red.svg" alt="SwiftUI"></a>
</p>

<p align="center">
  English | <a href="README.zh-CN.md">简体中文</a>
</p>

---

## 🌟 What is TidyFlow?

TidyFlow is a macOS-native multi-project development tool focused on parallel development across projects and branches, reducing context-switching overhead.

If you need to move multiple projects or feature branches forward at the same time, frequently switch between different AI agents, and jump quickly between terminal and file workflows, TidyFlow provides a unified workspace.

## ✨ Core Features

- 📂 **Parallel Multi-Project Management**: Manage multiple independent projects in one interface without interference.
- 🌿 **Native Git Worktree Support**: True branch isolation based on Git Worktree, so you can develop multiple branches in parallel without `git stash` or constant branch switching.
- 💻 **VS Code-Level Terminal Experience**: Built with xterm.js + real PTY, with full support for advanced TUI tools like `vim`, `tmux`, and `htop`, including 256-color and TrueColor.
- 🍎 **Authentic macOS Native Experience**: Built with SwiftUI + AppKit, aligned with macOS HIG, and optimized for keyboard-first workflows.
- ⚙️ **Rust Core Engine**: A Rust backend powering PTY management, Git operations, filesystem handling, and state persistence.

## 📸 UI Preview

![](./docs/images/screenshot.png)

## 🏗️ Architecture

TidyFlow uses a modern **hybrid native architecture**:

- **Frontend (UI Shell)**: A macOS-native app built with SwiftUI and AppKit for window management and system integration.
- **Terminal Container**: xterm.js running inside WKWebView for high-performance terminal rendering.
- **Core Engine (Backend)**: A high-performance Rust engine handling PTY management, Git operations, filesystem access, and state persistence.
- **Communication**: Frontend and backend communicate via WebSocket + MessagePack (binary, Protocol v2).

## ⌨️ Common Shortcuts

### Global
- `Cmd + Shift + P`: Open Command Palette
- `Cmd + P`: Quick Open files
- `Cmd + 1/2/3`: Switch right panel (Explorer/Search/Git)

### Workspace
- `Cmd + T`: New terminal tab
- `Cmd + W`: Close current tab
- `Cmd + Option + T`: Close other tabs
- `Ctrl + Tab`: Next tab
- `Ctrl + Shift + Tab`: Previous tab
- `Ctrl + 1-9`: Switch tab by index
- `Cmd + 1-9`: Switch workspace by shortcut

## 🛠️ Build from Source

If you want to build TidyFlow from source, make sure **Rust** and **Xcode** are installed.

### 1. Quick Start (Recommended)
```bash
./scripts/run-app.sh  # Build core + app and launch
```

### 2. Build Core Manually (Rust Core)
```bash
cd core
cargo build --release
```

### 3. Build App Manually (macOS App)
```bash
open app/TidyFlow.xcodeproj  # Open in Xcode and run (Cmd+R)
```

## 📦 Packaging & Release

The project supports automated signing and notarization so it runs smoothly on other macOS devices.

- **Build unsigned DMG**: `./scripts/build_dmg.sh`
- **Signed build**: `SIGN_IDENTITY="Developer ID..." ./scripts/build_dmg.sh --sign`
- **Notarize**: `./scripts/notarize.sh --profile tidyflow-notary`
- **Generate SHA256**: `./scripts/tools/gen_sha256.sh dist/<dmg-name>.dmg` (`build_dmg.sh` also generates this automatically)

Before release, run: [`docs/RELEASE_CHECKLIST.md`](docs/RELEASE_CHECKLIST.md)  
Version history: [`CHANGELOG.md`](CHANGELOG.md)

## 📄 License

This project is open source under **LGPL-3.0**.  
See [LICENSE](LICENSE) and [COPYING](COPYING) for details.
