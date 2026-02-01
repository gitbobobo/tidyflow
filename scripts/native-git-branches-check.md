# Phase C3-3a: Git Branch List + Switch - Verification Checklist

## Prerequisites
- [ ] Core server running (`cargo run` in core/)
- [ ] App built and running (Xcode)
- [ ] Connected to a git repository workspace

## Branch Display
- [ ] Git panel shows current branch name below "Git" title
- [ ] Branch name has branch icon (⎇) prefix
- [ ] Branch name has dropdown chevron (▼)
- [ ] Non-git repo: branch selector hidden

## Branch Picker
- [ ] Click branch name → popover opens
- [ ] Search field at top of popover
- [ ] All local branches listed
- [ ] Current branch has checkmark (✓)
- [ ] Current branch row is disabled (can't click)
- [ ] Type in search → filters branch list
- [ ] No matches → "No branches match 'xxx'" message

## Branch Switch - Success
- [ ] Click different branch → switch initiated
- [ ] Loading spinner shown during switch
- [ ] Toast: "Switched to branch 'xxx'"
- [ ] Current branch updates in UI
- [ ] Git status refreshes (file list may change)
- [ ] Open diff tabs closed (stale after switch)

## Branch Switch - Failure (Dirty Repo)
- [ ] Make uncommitted changes to a file
- [ ] Try to switch branch
- [ ] Error toast shows git error message
- [ ] Branch does NOT change
- [ ] Diff tabs remain open
