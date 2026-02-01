# TidyFlow UI 手工验收清单

> 发布前 UI 功能手工验收，覆盖所有用户可见交互

## 验收环境准备

1. 启动应用: `./scripts/run-app.sh`
2. 导入测试项目: 使用 workspace-demo 或任意 git 项目
3. 创建至少 2 个 workspace

---

## 1. Workspace 管理

### 1.1 Workspace 列表
- [ ] 左侧边栏显示所有 workspace
- [ ] 当前 workspace 高亮显示
- [ ] 点击切换 workspace 成功

### 1.2 Workspace 创建
- [ ] 可创建新 workspace
- [ ] 新 workspace 自动切换为当前

### 1.3 Workspace 删除
- [ ] 可删除非当前 workspace
- [ ] 删除后列表更新正确

---

## 2. Terminal (终端)

### 2.1 基本功能
- [ ] 终端正确显示 shell prompt
- [ ] 可输入命令并执行
- [ ] 输出正确显示（包括颜色）
- [ ] 支持 Ctrl+C 中断

### 2.2 交互
- [ ] 上下箭头浏览历史
- [ ] Tab 补全工作
- [ ] 复制粘贴正常 (Cmd+C/V)

### 2.3 多终端
- [ ] 可创建多个终端 tab
- [ ] 各终端独立运行
- [ ] 终端 cwd 与 workspace 一致

---

## 3. Tabs 系统

### 3.1 Tab 操作
- [ ] Cmd+T: 新建终端 tab
- [ ] Cmd+W: 关闭当前 tab
- [ ] Ctrl+Tab: 切换到下一个 tab
- [ ] Ctrl+Shift+Tab: 切换到上一个 tab

### 3.2 Tab 类型
- [ ] Terminal tab 显示正确图标
- [ ] Editor tab 显示文件名
- [ ] Diff tab 显示文件名 + diff 标识

### 3.3 Tab 状态
- [ ] 未保存文件显示修改标记
- [ ] 关闭未保存 tab 有确认提示

---

## 4. Editor (编辑器)

### 4.1 文件打开
- [ ] 双击文件树打开文件
- [ ] Cmd+P Quick Open 打开文件
- [ ] 文件内容正确显示

### 4.2 编辑功能
- [ ] 可正常输入文本
- [ ] Cmd+S 保存文件
- [ ] 保存后修改标记消失

### 4.3 语法高亮
- [ ] .js/.ts 文件有语法高亮
- [ ] .md 文件有 markdown 高亮
- [ ] .json 文件有 JSON 高亮

---

## 5. Command Palette (命令面板)

### 5.1 Quick Open (Cmd+P)
- [ ] 按 Cmd+P 打开文件搜索
- [ ] 输入文件名可搜索
- [ ] 选择文件后打开
- [ ] ESC 关闭面板

### 5.2 Commands (Cmd+Shift+P)
- [ ] 按 Cmd+Shift+P 打开命令面板
- [ ] 显示可用命令列表
- [ ] 输入可过滤命令
- [ ] 选择命令后执行

### 5.3 命令验证
- [ ] "New Terminal" 命令可用
- [ ] "Refresh File Index" 命令可用
- [ ] "Toggle Git Panel" 命令可用

---

## 6. Git Panel (Git 面板)

### 6.1 状态显示
- [ ] 右侧面板显示 Git 状态
- [ ] Modified 文件显示 M 标记
- [ ] Added 文件显示 A 标记
- [ ] Deleted 文件显示 D 标记
- [ ] Untracked 文件显示 ? 标记

### 6.2 文件操作
- [ ] 点击文件打开 diff
- [ ] 可展开/折叠文件组

---

## 7. Diff Viewer (Diff 视图)

### 7.1 Unified View
- [ ] 默认显示 unified diff
- [ ] 添加行显示绿色背景
- [ ] 删除行显示红色背景
- [ ] 行号正确显示

### 7.2 Split View
- [ ] 可切换到 split view
- [ ] 左侧显示原文件
- [ ] 右侧显示修改后
- [ ] 对应行对齐

### 7.3 模式切换
- [ ] Working/Staged 切换按钮可见
- [ ] Working 模式显示未暂存更改
- [ ] Staged 模式显示已暂存更改

### 7.4 导航
- [ ] 可滚动查看长 diff
- [ ] 行号可点击定位

---

## 8. Workspace 切换状态保持

### 8.1 Tab 保持
- [ ] 切换 workspace 后原 tabs 保留
- [ ] 切回后 tabs 恢复

### 8.2 编辑状态
- [ ] 未保存的编辑内容保留
- [ ] 终端历史保留

---

## 9. 快捷键汇总验证

| 快捷键 | 功能 | 验证 |
|--------|------|------|
| Cmd+P | Quick Open | [ ] |
| Cmd+Shift+P | Command Palette | [ ] |
| Cmd+T | New Terminal | [ ] |
| Cmd+W | Close Tab | [ ] |
| Cmd+S | Save File | [ ] |
| Ctrl+Tab | Next Tab | [ ] |
| Ctrl+Shift+Tab | Prev Tab | [ ] |
| ESC | Close Palette | [ ] |

---

## 10. 边界情况

### 10.1 空状态
- [ ] 无 workspace 时显示引导
- [ ] 无文件时 Cmd+P 显示空列表

### 10.2 错误处理
- [ ] 打开不存在文件显示错误
- [ ] 保存只读文件显示错误
- [ ] 网络断开时显示重连提示

---

## 验收结果

- 验收日期: ____________
- 验收人: ____________
- 通过项: ______ / 总计
- 阻断问题:
  1. ____________
  2. ____________
- 备注: ____________
