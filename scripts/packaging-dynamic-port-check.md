# D3b-1 Dynamic Port Verification Checklist

## Basic Functionality

- [ ] 1. Build app: `xcodebuild -scheme TidyFlow -configuration Debug build`
- [ ] 2. Launch app without manually starting Core
- [ ] 3. Verify status shows "Running :XXXXX" (dynamic port, not 47999)
- [ ] 4. Verify Cmd+P (Quick Open) works
- [ ] 5. Verify Terminal tab connects
- [ ] 6. Verify Git panel loads status

## Port Conflict Handling

- [ ] 7. Occupy a port: `nc -l 49152 &`
- [ ] 8. Launch app, verify it uses different port
- [ ] 9. Check status shows retry attempt if needed
- [ ] 10. Kill nc: `killall nc`

## Multiple Instances

- [ ] 11. Launch first app instance
- [ ] 12. Note the port (e.g., :49152)
- [ ] 13. Launch second app instance
- [ ] 14. Verify second instance uses different port
- [ ] 15. Both instances functional independently

## Process Cleanup

- [ ] 16. Launch app, note Core PID from tooltip
- [ ] 17. Quit app (Cmd+Q)
- [ ] 18. Verify Core process terminated: `ps aux | grep tidyflow-core`
- [ ] 19. No orphan processes remain

## Recovery (Cmd+R)

- [ ] 20. Launch app, wait for Running state
- [ ] 21. Press Cmd+R
- [ ] 22. Verify Core restarts (may get new port)
- [ ] 23. Verify WS reconnects automatically
- [ ] 24. All features work after restart
