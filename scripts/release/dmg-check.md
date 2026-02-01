# DMG 手工验收 Checklist

## 构建验证
- [ ] 运行 `./scripts/release/build_dmg.sh` 成功
- [ ] 产出 `dist/TidyFlow-*.dmg` 文件

## 安装验证
- [ ] 双击 DMG 可正常挂载
- [ ] 可见 TidyFlow.app 和 Applications 快捷方式
- [ ] 拖拽 TidyFlow.app 到 Applications 成功

## 首次启动 (Gatekeeper)
- [ ] 首次双击会被 Gatekeeper 拦截（"无法打开"）
- [ ] 右键 > 打开 > 点击"打开"可绕过
- [ ] 或: 系统设置 > 隐私与安全 > 点击"仍要打开"

## 功能验证
- [ ] TopToolbar 显示 "Running :PORT"
- [ ] Debug Panel (Cmd+D) 可见 core.log 写入
- [ ] Cmd+P 可列出文件（证明 WS 连通）
- [ ] 终端 Tab 可正常使用
