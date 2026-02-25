# Evolution UI 截图证据策略

> 文档版本：1.2 | 更新日期：2026-02-25

## 1. 必采状态

每次验证至少采集以下三态（macOS 与 iOS 同构）：

- `empty`
- `loading`
- `ready`

最小合格集：每个平台均为 `empty + loading + ready`。

## 2. 命名与路径

统一命名：

```text
screenshot-<cycle_id>-<check_id>-<platform>-<state>-<utc_ts>.png
```

示例：

```text
.tidyflow/evolution/<cycle_id>/evidence/screenshots/screenshot-2026-02-25T06-00-02-292Z-v-4-ios-loading-20260225T061122Z.png
```

命名必须可反查：`cycle_id/check_id/platform/state`。

## 3. 采集步骤（v-4）

1. 在 macOS 与 iOS 分别打开 AI 聊天核心页。
2. 每端按 `empty/loading/ready` 依次采集截图。
3. 将产物放入本 cycle `evidence/` 目录，并写入 `evidence.index.json`。

无 GUI 环境时不允许生成 synthetic/占位截图充当证据；若无法采集真实截图，必须显式登记缺失项并写明 `missing_reason`，由 direction/verify/judge 阶段据实判定为证据不足。

## 4. 索引字段要求

截图条目至少包含：
- `type=screenshot`
- `check_id=v-4`
- `run_id`
- `summary`（包含平台与状态）
- `status` 与 `missing_reason`（若缺失）

## 5. 失败处理

截图失败时必须：
- 输出可直接执行的补拍步骤；
- 在证据索引中记录 `status=missing` 与 `missing_reason`；
- 不阻断其它证据写入。

截图质量校验（v-4 最小门槛）：
- 分辨率不得低于 `720x1280`（或同等像素量）；
- 双端三态 6 张图的 `sha256` 不得全部相同；
- `summary` 或附加校验文件必须能反查 `platform/state`。

## 6. 跨端一致性要求

发布前需同时确认：
- macOS 构建证据（v-2）存在；
- iOS 构建证据（v-3）存在；
- `v-4` 的双端三态截图均可追溯到同一 `run_id`。
