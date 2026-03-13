#!/usr/bin/env python3
"""证据索引完整性校验脚本

根据 run_id 检查 evidence.index.json 是否覆盖指定设备目录和核心场景。
供 verify 阶段和 quality-gate --verify-only 直接调用。

校验阶段（8 步）：
  1. 证据根目录存在
  2. evidence.index.json 存在且可解析
  3. run_id 匹配条目过滤
  4. 设备覆盖检查
  5. 场景覆盖检查
  6. 路径契约校验（相对路径、无 ..、设备前缀一致）
  7. 实际产物存在性
  8. 证据类型完整性（每设备需有 log + screenshot）

输出格式：
  --json: 可机读 JSON（含 project/workspace/run_id/错误分类）
  默认: 人类可读文本

用法示例:
    python3 scripts/e2e/verify_evidence_index.py \
        --evidence-root .tidyflow/evidence \
        --run-id verify-cross-platform-core \
        --project tidyflow \
        --workspace default \
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
    parser.add_argument("--project", default="tidyflow", help="项目名（默认: tidyflow）")
    parser.add_argument("--workspace", default="default", help="工作区名（默认: default）")
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
    parser.add_argument(
        "--json", action="store_true", dest="json_output",
        help="输出可机读 JSON 摘要",
    )
    parser.add_argument(
        "--skip-evidence-type-check",
        action="store_true",
        dest="skip_type_check",
        help="跳过证据类型完整性检查（log+screenshot）。性能场景按需校验时使用，不影响默认行为。",
    )
    args = parser.parse_args()

    evidence_root: str = os.path.realpath(args.evidence_root)
    run_id: str = args.run_id
    project: str = args.project
    workspace: str = args.workspace
    require_devices: list[str] = args.require_devices
    require_scenarios: list[str] = args.require_scenarios

    # 错误分类收集
    errors: list[dict] = []

    def add_error(category: str, message: str) -> None:
        errors.append({"category": category, "message": message})

    # 1. 检查证据根目录存在
    if not os.path.isdir(evidence_root):
        add_error("root_missing", f"证据根目录不存在: {evidence_root}")
        _emit_result(args, project, workspace, run_id, errors, 0)
        sys.exit(1)

    # 2. 检查 evidence.index.json 存在并解析
    index_path = os.path.join(evidence_root, "evidence.index.json")
    if not os.path.exists(index_path):
        add_error("index_missing", f"证据索引文件不存在: {index_path}")
        _emit_result(args, project, workspace, run_id, errors, 0)
        sys.exit(1)

    try:
        with open(index_path, encoding="utf-8") as f:
            index = json.load(f)
    except json.JSONDecodeError as exc:
        add_error("index_parse_error", f"证据索引 JSON 解析失败: {exc}")
        _emit_result(args, project, workspace, run_id, errors, 0)
        sys.exit(1)

    items: list[dict] = index.get("items", [])

    # 3. 按 run_id 过滤证据条目
    run_items: list[dict] = []
    for item in items:
        item_run_id = item.get("run_id") or ""
        item_id = item.get("id") or ""
        item_path = item.get("path") or ""
        item_workspace_context = item.get("workspace_context") or ""
        if (
            item_run_id == run_id
            or run_id in item_id
            or run_id in item_path
            or f"run_id={run_id}" in item_workspace_context
        ):
            run_items.append(item)

    # 4. 检查设备覆盖
    found_devices: set[str] = {i.get("device_type") for i in run_items if i.get("device_type")}
    for device in require_devices:
        if device not in found_devices:
            add_error("device_missing", f"设备 {device!r} 在 run_id={run_id!r} 中无证据条目")

    # 5. 检查场景覆盖（大小写不敏感）
    for scenario_prefix in require_scenarios:
        slug = scenario_prefix.lower()
        found = any(
            slug in (i.get("scenario") or "").lower()
            or slug in (i.get("path") or "").lower()
            for i in run_items
        )
        if not found:
            add_error("scenario_missing", f"场景 {scenario_prefix!r} 在 run_id={run_id!r} 中无证据条目")

    # 6. 路径契约校验
    for item in run_items:
        path = item.get("path", "")
        device = item.get("device_type", "")
        item_id = item.get("id", "<unknown>")

        if not path:
            add_error("path_empty", f"条目 {item_id!r} 路径为空")
            continue
        if path.startswith("/"):
            add_error("path_absolute", f"条目 {item_id!r} 路径为绝对路径: {path}")
            continue
        if ".." in path:
            add_error("path_traversal", f"条目 {item_id!r} 路径包含 '..': {path}")
            continue
        if device and not path.startswith(f"{device}/"):
            add_error("path_device_mismatch", f"条目 {item_id!r} 路径未以设备类型开头: device={device}, path={path}")

    # 7. 实际产物存在性
    for item in run_items:
        path = item.get("path", "")
        if not path or path.startswith("/") or ".." in path:
            continue
        full_path = os.path.join(evidence_root, path)
        if not os.path.exists(full_path):
            add_error("artifact_missing", f"证据产物不存在: {path}")

    # 8. 证据类型完整性（每设备需有 log + screenshot）
    if not getattr(args, "skip_type_check", False):
        for device in require_devices:
            device_items = [i for i in run_items if i.get("device_type") == device]
            device_types = {str(i.get("type", "")) for i in device_items}
            for required_type in ("log", "screenshot"):
                if required_type not in device_types:
                    add_error("type_missing", f"设备 {device!r} 缺少证据类型: {required_type}")

    # 检查设备证据目录存在
    for device in require_devices:
        device_run_dir = os.path.join(evidence_root, device, "e2e", run_id)
        if not os.path.isdir(device_run_dir):
            add_error("device_dir_missing", f"设备证据目录不存在: {device_run_dir}")

    # 汇报结果
    _emit_result(args, project, workspace, run_id, errors, len(run_items))

    if errors:
        sys.exit(1)
    else:
        sys.exit(0)


def _emit_result(
    args,
    project: str,
    workspace: str,
    run_id: str,
    errors: list[dict],
    item_count: int,
) -> None:
    """输出校验结果"""
    if getattr(args, "json_output", False):
        result = {
            "evidence_verification": {
                "project": project,
                "workspace": workspace,
                "run_id": run_id,
                "overall": "fail" if errors else "pass",
                "total_items": item_count,
                "error_count": len(errors),
                "errors": errors,
            }
        }
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        if errors:
            print(
                f"[verify] 证据校验失败，发现 {len(errors)} 个问题 "
                f"(project={project} workspace={workspace} run_id={run_id}):",
                file=sys.stderr,
            )
            for err in errors:
                print(f"  - [{err['category']}] {err['message']}", file=sys.stderr)
        else:
            print(
                f"[verify] 证据校验通过: project={project} workspace={workspace} run_id={run_id}"
                f" devices={args.require_devices}"
                f" scenarios={args.require_scenarios}"
            )
            print(f"[verify] 总条目: {item_count}")


if __name__ == "__main__":
    main()
