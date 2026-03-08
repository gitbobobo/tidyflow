#!/usr/bin/env python3
"""证据索引完整性校验脚本

根据 run_id 检查 evidence.index.json 是否覆盖指定设备目录和核心场景。
供 verify 阶段直接调用，不需要人工浏览目录。

用法示例:
    python3 scripts/e2e/verify_evidence_index.py \
        --evidence-root .tidyflow/evidence \
        --run-id verify-cross-platform-core \
        --require-devices iphone ipad mac \
        --require-scenarios AC-WORKSPACE-LIFECYCLE AC-AI-SESSION-FLOW AC-TERMINAL-INTERACTION
"""
import argparse
import json
import os
import sys


def main() -> None:
    parser = argparse.ArgumentParser(
        description="验证 E2E 证据索引完整性",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--evidence-root", required=True, help="证据根目录路径")
    parser.add_argument("--run-id", required=True, help="E2E 运行 ID")
    parser.add_argument(
        "--require-devices",
        nargs="+",
        default=["iphone", "ipad", "mac"],
        help="必须存在证据的设备列表（默认: iphone ipad mac）",
    )
    parser.add_argument(
        "--require-scenarios",
        nargs="+",
        default=[
            "AC-WORKSPACE-LIFECYCLE",
            "AC-AI-SESSION-FLOW",
            "AC-TERMINAL-INTERACTION",
        ],
        help="必须存在证据的场景前缀列表（大小写不敏感匹配）",
    )
    args = parser.parse_args()

    evidence_root: str = os.path.realpath(args.evidence_root)
    run_id: str = args.run_id
    require_devices: list[str] = args.require_devices
    require_scenarios: list[str] = args.require_scenarios

    errors: list[str] = []

    # 1. 检查证据根目录存在
    if not os.path.isdir(evidence_root):
        print(f"[verify] 错误: 证据根目录不存在: {evidence_root}", file=sys.stderr)
        sys.exit(1)

    # 2. 检查 evidence.index.json 存在
    index_path = os.path.join(evidence_root, "evidence.index.json")
    if not os.path.exists(index_path):
        print(f"[verify] 错误: 证据索引文件不存在: {index_path}", file=sys.stderr)
        sys.exit(1)

    # 3. 加载并解析索引
    try:
        with open(index_path, encoding="utf-8") as f:
            index = json.load(f)
    except json.JSONDecodeError as exc:
        print(f"[verify] 错误: 证据索引 JSON 解析失败: {exc}", file=sys.stderr)
        sys.exit(1)

    items: list[dict] = index.get("items", [])

    # 4. 按 run_id 过滤证据条目
    # run_id 出现在 id 字段或 path 字段中
    run_items: list[dict] = [
        i for i in items
        if run_id in (i.get("id") or "") or run_id in (i.get("path") or "")
    ]

    print(f"[verify] run_id={run_id} 共找到 {len(run_items)} 条证据条目")

    # 5. 检查设备覆盖
    found_devices: set[str] = {i.get("device_type") for i in run_items if i.get("device_type")}
    for device in require_devices:
        if device not in found_devices:
            errors.append(f"设备 {device!r} 在 run_id={run_id!r} 中无证据条目")

    # 6. 检查场景覆盖（大小写不敏感，匹配 scenario 字段或 path 中的场景目录）
    for scenario_prefix in require_scenarios:
        slug = scenario_prefix.lower()
        found = any(
            slug in (i.get("scenario") or "").lower()
            or slug in (i.get("path") or "").lower()
            for i in run_items
        )
        if not found:
            errors.append(f"场景 {scenario_prefix!r} 在 run_id={run_id!r} 中无证据条目")

    # 7. 检查设备证据目录存在
    for device in require_devices:
        device_run_dir = os.path.join(evidence_root, device, "e2e", run_id)
        if not os.path.isdir(device_run_dir):
            errors.append(f"设备证据目录不存在: {device_run_dir}")

    # 8. 汇报结果
    if errors:
        print(
            f"[verify] 证据校验失败，发现 {len(errors)} 个问题:",
            file=sys.stderr,
        )
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        sys.exit(1)
    else:
        print(
            f"[verify] 证据校验通过: run_id={run_id}"
            f" devices={require_devices}"
            f" scenarios={require_scenarios}"
        )
        print(f"[verify] 总条目: {len(run_items)}")
        sys.exit(0)


if __name__ == "__main__":
    main()
