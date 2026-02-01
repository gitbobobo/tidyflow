# Split Diff 设计文档

## 概述

Diff Tab 支持两种视图模式：
- **Unified** (默认) - 传统的 unified diff 格式
- **Split** - 左右对比视图 (Old | New)

## 数据结构

### 解析后的 Diff 结构

```typescript
interface DiffData {
  headers: string[];      // diff --git, index, ---, +++ 等头部行
  hunks: Hunk[];          // 变更块列表
  path: string;           // 文件路径
}

interface Hunk {
  oldStart: number;       // 旧文件起始行号
  newStart: number;       // 新文件起始行号
  header: string;         // @@ -x,y +a,b @@ 完整行
  context: string;        // @@ 后的函数上下文
  lines: LineInfo[];      // 行内容列表
}

interface LineInfo {
  type: 'context' | 'add' | 'del' | 'meta';
  oldLine: number | null; // 旧文件行号 (add 时为 null)
  newLine: number | null; // 新文件行号 (del 时为 null)
  text: string;           // 原始行文本 (含 +/- 前缀)
}
```

### Tab 扩展字段

```typescript
interface DiffTabInfo {
  // ... 原有字段 ...
  viewMode: 'unified' | 'split';  // 当前视图模式
  diffData: DiffData | null;      // 解析后的 diff 数据
  rawText: string | null;         // 原始 diff 文本
  isBinary: boolean;
  truncated: boolean;
}
```

## Split Diff 渲染规则

### 行对齐策略

1. **Context 行**: 左右两栏同时显示相同内容
2. **Del 行**: 左栏显示，右栏显示空占位
3. **Add 行**: 左栏显示空占位，右栏显示
4. **连续 Del+Add**: 配对显示，实现修改行的左右对比

### 配对算法

```
输入: [del, del, add, add, add, context]
输出:
  Row 1: { old: del1, new: add1 }
  Row 2: { old: del2, new: add2 }
  Row 3: { old: null, new: add3 }
  Row 4: { old: context, new: context }
```

### 行号显示

- 左栏: 显示 `oldLine` (存在时)
- 右栏: 显示 `newLine` (存在时)
- 空占位行: 不显示行号

## 点击跳转行为

| 点击位置 | 跳转目标 |
|----------|----------|
| 右栏 (New) | 跳转到 `newLine` |
| 左栏 (Old) | 跳转到对应的 `newLine` (或最近的 context 行) |
| 删除行 | 跳转到最近的 `newLine` |

## 自动回退策略

### 大文件限制

当 diff 行数超过 **5000 行** 时：
- 自动禁用 Split 模式
- Split 按钮变为 disabled 状态
- 显示提示: "Diff too large for split view (N lines)"
- 强制使用 Unified 模式

### 不支持的场景

以下场景禁用 Split 模式：
- Binary 文件
- 已删除文件 (code === 'D')
- 空 diff

## UI 组件

### 视图切换按钮

位于 Diff Tab 工具栏，Refresh 按钮之后：

```
[📄 Open file] [↻ Refresh] [Unified | Split]
```

- 当前模式按钮高亮 (蓝色背景)
- 切换时不重新请求 diff
- 保持滚动位置 (近似)

### Split 视图布局

```
+--------------------------------------------------+
| diff --git a/file.txt b/file.txt                 |  <- headers
| index abc123..def456 100644                      |
+--------------------------------------------------+
| @@ -10,5 +10,6 @@ function foo()                 |  <- hunk header
+------------------------+-------------------------+
| 10 | old line 1       | 10 | new line 1         |  <- context
| 11 | - deleted        |    |                    |  <- del
|    |                  | 11 | + added            |  <- add
| 12 | context          | 12 | context            |  <- context
+------------------------+-------------------------+
```

## CSS 类名

| 类名 | 用途 |
|------|------|
| `.diff-view-toggle` | 视图切换按钮容器 |
| `.diff-view-btn` | 单个切换按钮 |
| `.diff-view-btn.active` | 当前激活的模式 |
| `.diff-split-container` | Split 视图根容器 |
| `.diff-split` | 单个 hunk 的左右分栏 |
| `.diff-split-pane` | 左/右栏 |
| `.diff-split-row` | 单行容器 |
| `.diff-line-num` | 行号 |
| `.diff-line-text` | 行内容 |
| `.diff-split-empty` | 空占位行 |

## 限制

1. **不支持字符级 diff** - 仅行级对比
2. **不支持虚拟滚动** - 大文件性能受限
3. **不支持 staged diff** - 仅 working tree diff
4. **不支持 word wrap** - 长行需水平滚动

## 相关文档

- `design/19-git-tools.md` - Git 工具面板设计
- `design/20-diff-navigation.md` - Diff 行跳转设计
