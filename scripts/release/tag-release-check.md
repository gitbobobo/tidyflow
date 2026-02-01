# Tag Release 验收检查清单

## 发布步骤

```bash
# 1. 确保代码已提交
git status  # 应无未提交更改

# 2. 创建 tag
git tag v1.0.0

# 3. 推送 tag
git push origin v1.0.0
```

## 验收点

- [ ] GitHub Actions 触发 "Release on Tag" workflow
- [ ] Job 状态：成功（绿色）
- [ ] GitHub Releases 页面出现新 Release
- [ ] Release 名称：`TidyFlow v1.0.0`
- [ ] Assets 包含：`TidyFlow-*.dmg`
- [ ] 下载 DMG，双击可直接运行（无 Gatekeeper 警告）

## 常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| Workflow 未触发 | Tag 格式不对 | 确保以 `v` 开头 |
| Secrets 验证失败 | 缺少配置 | 检查 repo Settings > Secrets |
| 公证失败 | API Key 问题 | 检查 ASC_* secrets |
