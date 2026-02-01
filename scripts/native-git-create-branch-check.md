# Native Git Create Branch Verification Checklist (Phase C3-3b)

## Prerequisites
- [ ] Core server running (`cargo run`)
- [ ] App connected to Core (green status indicator)
- [ ] Git panel visible (Cmd+3)

## Create Branch - Success Cases
1. [ ] Open branch picker (click current branch name)
2. [ ] Click "+ Create new branch..."
3. [ ] Type "feature/test-c3-3b" -> Create button enabled
4. [ ] Click Create -> spinner shows, inputs disabled
5. [ ] Success -> picker closes, toast "Created and switched to 'feature/test-c3-3b'"
6. [ ] Branch list shows new branch as current (checkmark)
7. [ ] Git status refreshed

## Validation - Client-Side Rejection
8. [ ] Empty name -> Create disabled, "Branch name required"
9. [ ] "bad name" (space) -> Create disabled, "Cannot contain spaces"
10. [ ] "-branch" (leading dash) -> Create disabled, "Cannot start with '-'"
11. [ ] "branch." (trailing dot) -> Create disabled, "Cannot end with '.'"
12. [ ] "branch..name" -> Create disabled, "Cannot contain '..'"
13. [ ] "branch~1" or "branch^2" -> Create disabled, "Invalid characters"

## Error Cases - Server-Side
14. [ ] Type existing branch name -> "Branch already exists" (client-side check)
15. [ ] Dirty repo with conflicts -> toast shows git error message

## Cancel Flow
16. [ ] Click Cancel -> form collapses, name cleared
17. [ ] Press Escape -> form collapses (if implemented)
