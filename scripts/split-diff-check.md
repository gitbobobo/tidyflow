# Split Diff 手工验收步骤

## 前置条件
- TidyFlow 已启动
- 已选择一个 Workspace

## 验收步骤

### 1. 基本功能
1. 修改一个文件 (添加/删除/修改若干行)
2. 打开 Git 面板，点击该文件
3. 确认 Diff Tab 打开，默认显示 Unified 视图
4. 点击 "Split" 按钮，确认切换到左右对比视图

### 2. Split 视图验证
- [ ] 左栏显示旧版本 (删除行 + context)
- [ ] 右栏显示新版本 (新增行 + context)
- [ ] 删除行显示红色背景
- [ ] 新增行显示绿色背景
- [ ] 行号正确显示

### 3. 行对齐验证
- [ ] Context 行左右对齐
- [ ] 连续的删除+新增行配对显示
- [ ] 空占位行正确填充

### 4. 点击跳转验证
- [ ] 点击右栏新增行 → Editor 跳转到正确行
- [ ] 点击左栏删除行 → Editor 跳转到最近的新行
- [ ] 点击 context 行 → Editor 跳转到对应行

### 5. 视图切换验证
- [ ] Unified → Split 不重新请求 diff
- [ ] Split → Unified 不重新请求 diff
- [ ] 切换后滚动位置大致保持

### 6. 大文件回退验证
1. 创建一个大 diff (>5000 行变更)
2. 打开 Diff Tab
3. 确认 Split 按钮被禁用
4. 确认显示 "Diff too large" 提示

### 7. 边界情况
- [ ] 删除文件: Split 按钮禁用
- [ ] Binary 文件: Split 按钮禁用
- [ ] 空 diff: Split 按钮禁用

---

## Staged Diff 验收步骤

### 8. Working/Staged 切换
1. 修改一个 tracked 文件但不 add
2. 打开 Diff Tab，确认默认显示 Working 模式
3. 确认 Working 按钮高亮，diff 有内容
4. 点击 Staged 按钮
5. 确认 Staged 按钮高亮，diff 为空

### 9. Staged 模式验证
1. `git add` 该文件
2. 刷新或重新打开 Diff Tab
3. Working 模式: diff 应为空
4. Staged 模式: diff 应有内容

### 10. Untracked 文件
- [ ] Working 模式: 显示完整文件内容
- [ ] Staged 模式: 显示空 diff (untracked 无 staged 变更)

### 11. 模式切换不新建 Tab
- [ ] 切换 Working/Staged 复用当前 Tab
- [ ] 切换后重新请求 diff 并刷新视图
- [ ] Split 视图在切换模式后正确重建
