# Evolution UI 截图证据策略

> 文档版本：1.1 | 更新日期：2026-02-24

## 1. 必采状态

每次验证至少采集以下三态：

- `initial`
- `processing`
- `complete` 或 `error`

最小合格集：`initial + processing + (complete|error)`。

## 2. 命名与路径

统一命名：

```text
screenshot-<cycle_id>-<check_id>-<state>-<utc_ts>.png
```

示例：

```text
.tidyflow/evolution/<cycle_id>/evidence/screenshot-2026-02-24T12-01-45Z_tidyflow_default_xxx-v-6-processing-20260224T123501Z.png
```

命名必须能反查 `cycle_id/check_id/state`。

## 3. 采集命令

```bash
./scripts/evo-screenshot.sh --cycle <cycle_id> --check v-6 --state initial
./scripts/evo-screenshot.sh --cycle <cycle_id> --check v-6 --state processing
./scripts/evo-screenshot.sh --cycle <cycle_id> --check v-6 --state complete
```

无 GUI 环境可用：

```bash
./scripts/evo-screenshot.sh --cycle <cycle_id> --check v-6 --state initial --dry-run
```

## 4. 日志关联

截图写入索引时需附加：

- `run_id`
- `check_id`
- `metadata.state`
- `metadata.related_test_log`

这样可从截图回溯到同一 run 的 `test_log`。

## 5. 失败处理

截图失败时必须：

- 立即输出重试命令；
- 在 `runs/<run_id>/evidence/diff-<run_id>.md` 追加缺失原因；
- 保留其他证据，不阻断索引更新。

## 6. 跨端一致性要求

发布前需同时确认：

- macOS 构建证据（v-3）存在；
- iOS 构建证据（v-4）存在；
- UI 三态截图已归档并可追溯。
