# Native Git Commit Check (Phase C3-4a)

## Prerequisites
- [ ] Core server running (`cargo run`)
- [ ] App connected to Core
- [ ] Git repository with some changes

## Verification Checklist

### 1. Staged Changes Detection
- [ ] Git panel shows "No staged changes" when nothing staged
- [ ] After staging a file, shows "N file(s) staged"
- [ ] Commit button disabled when no staged changes

### 2. Commit Message Validation
- [ ] Commit button disabled when message is empty
- [ ] Commit button disabled when message is whitespace only
- [ ] Commit button enabled when message has content AND staged changes

### 3. Successful Commit
- [ ] Stage a file, enter message "test commit", click Commit
- [ ] Toast shows "Committed: <sha>"
- [ ] Message input cleared after success
- [ ] Git status refreshed (staged file disappears)

### 4. Error Handling
- [ ] Empty message: Button disabled (UI prevents)
- [ ] No staged changes: Button disabled (UI prevents)
- [ ] Git identity not configured: Toast shows helpful message

### 5. UI States
- [ ] Commit button shows spinner during commit
- [ ] Input disabled during commit
- [ ] Enter key triggers commit when valid

## Quick Test Sequence

```bash
# In test repo:
echo "test" >> testfile.txt
# In app: Stage testfile.txt
# In app: Enter "test: add testfile" in commit message
# In app: Click Commit
# Verify: Toast shows success with SHA
# Verify: testfile.txt no longer in changes list
# Verify: git log shows new commit
```
