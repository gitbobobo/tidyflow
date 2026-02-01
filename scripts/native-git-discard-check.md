# Native Git Discard Verification Checklist (Phase C3-2b)

## Single File Discard
- [ ] Modify a tracked file → hover → click Discard → confirm → file restored
- [ ] Create untracked file → hover → click Discard → confirm → file deleted
- [ ] Discard button shows `trash` icon for untracked, `arrow.uturn.backward` for tracked
- [ ] Confirmation dialog shows "Delete File?" for untracked files
- [ ] Confirmation dialog shows "Discard Changes?" for tracked files

## Discard All
- [ ] Multiple modified files → click "Discard All" → confirm → all tracked files restored
- [ ] Untracked files remain after "Discard All" (safety feature)
- [ ] "Discard All" button disabled when no tracked changes exist

## Staged File Protection
- [ ] Staged-only file → Discard button is disabled
- [ ] Tooltip explains "Cannot discard staged-only changes"

## Post-Operation Behavior
- [ ] Git status refreshes automatically after discard
- [ ] Open diff tab for discarded file → tab closes automatically
- [ ] Toast shows "Discarded changes in <path>" or "Deleted <path>"

## Error Handling
- [ ] Discard fails → error toast displayed
- [ ] Disconnected state → shows "Disconnected" toast
