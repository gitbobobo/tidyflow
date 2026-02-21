# Evolution Prompt 职责边界（去重基线）

## 目标

用于约束各阶段提示词职责，避免同一能力被多个代理重复执行或互相覆盖。

## 阶段职责矩阵

| 阶段 | 主职责 | 主写文件 | 禁止事项 |
| --- | --- | --- | --- |
| bootstrap | 现状摸底、测试基座、外部环境收集 | `stage.bootstrap.json` `bootstrap.state.json` `test.adapter.json` `env.contract.json` `env.values.local.json` | 禁止修改业务功能代码 |
| direction | 方向选择、验收口径定义 | `stage.direction.json` `direction.lifecycle_scan.json` | 禁止环境问答，禁止实现代码 |
| plan | 执行计划拆解 | `stage.plan.json` `plan.execution.json` | 禁止环境问答，禁止实现代码 |
| implement | 代码实施与初步证据 | `stage.implement.json` `implement.result.json` | 禁止重定义测试基座契约 |
| verify | 基于基座执行验证 | `stage.verify.json` `verify.result.json` | 禁止环境问答，禁止功能扩展 |
| judge | 裁决与回路决策 | `stage.judge.json` `judge.result.json` | 禁止实现与验证动作 |
| report | 汇总与下一轮建议 | `stage.report.json` `report.result.json` `report.md` | 禁止新决策实现 |

## 提问权限边界

1. 仅 `bootstrap` 允许向用户提问。
2. 提问范围仅限“外部服务运行环境缺失项”。
3. 其他阶段必须保持“禁止向用户提问”。

## 文件主写边界

1. `bootstrap.state.json` 仅 bootstrap 主写。
2. `test.adapter.json` 仅 bootstrap 主写；verify 只读消费。
3. `env.contract.json` / `env.values.local.json` 仅 bootstrap 主写。
4. `verify.result.json` 仅 verify 主写。
5. `judge.result.json` 仅 judge 主写。

## 去重检查清单

1. 检查每个阶段 prompt 是否包含其他阶段主写文件的写入指令。
2. 检查是否存在重复“用户问答”指令。
3. 检查 verify 是否仍包含“自行猜测测试入口”的描述（应改为优先读取 `test.adapter.json`）。
4. 检查 direction/plan 是否包含 bootstrap 已覆盖的环境采集行为。

