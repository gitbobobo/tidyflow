#!/usr/bin/env python3
"""
Multi-Terminal Smoke Test for TidyFlow
Tests: create two terminals, verify independent I/O, close both
"""

import asyncio
import json
import base64
import sys
import os

try:
    import websockets
except ImportError:
    print("ERROR: websockets not installed. Run: pip3 install websockets")
    sys.exit(1)

WS_URL = "ws://127.0.0.1:47999/ws"
TIMEOUT = 10

class TerminalTester:
    def __init__(self):
        self.ws = None
        self.term_ids = []
        self.outputs = {}  # term_id -> accumulated output
        self.project = None
        self.workspace = None

    async def connect(self):
        self.ws = await asyncio.wait_for(
            websockets.connect(WS_URL),
            timeout=TIMEOUT
        )
        # Wait for hello
        msg = await self.recv()
        assert msg["type"] == "hello", f"Expected hello, got {msg['type']}"
        self.term_ids.append(msg["session_id"])
        self.outputs[msg["session_id"]] = ""
        print(f"[OK] Connected, default term: {msg['session_id'][:8]}")
        return msg["session_id"]

    async def send(self, msg):
        await self.ws.send(json.dumps(msg))

    async def recv(self):
        data = await asyncio.wait_for(self.ws.recv(), timeout=TIMEOUT)
        return json.loads(data)

    async def recv_until(self, msg_type, term_id=None, timeout=TIMEOUT):
        """Receive messages until we get the expected type"""
        deadline = asyncio.get_event_loop().time() + timeout
        while asyncio.get_event_loop().time() < deadline:
            try:
                msg = await asyncio.wait_for(
                    self.ws.recv(),
                    timeout=deadline - asyncio.get_event_loop().time()
                )
                parsed = json.loads(msg)

                # Accumulate output
                if parsed["type"] == "output":
                    tid = parsed.get("term_id") or self.term_ids[0]
                    if tid in self.outputs:
                        data = base64.b64decode(parsed["data_b64"]).decode("utf-8", errors="replace")
                        self.outputs[tid] += data

                if parsed["type"] == msg_type:
                    if term_id is None or parsed.get("term_id") == term_id:
                        return parsed
            except asyncio.TimeoutError:
                break
        return None

    async def setup_workspace(self):
        """Find or create a test workspace"""
        # List projects
        await self.send({"type": "list_projects"})
        msg = await self.recv_until("projects")

        if not msg or not msg.get("items"):
            print("[SKIP] No projects found. Create a project first.")
            return False

        self.project = msg["items"][0]["name"]
        print(f"[OK] Using project: {self.project}")

        # List workspaces
        await self.send({"type": "list_workspaces", "project": self.project})
        msg = await self.recv_until("workspaces")

        if not msg or not msg.get("items"):
            print("[SKIP] No workspaces found. Create a workspace first.")
            return False

        self.workspace = msg["items"][0]["name"]
        print(f"[OK] Using workspace: {self.workspace}")
        return True

    async def create_terminal(self):
        """Create a new terminal in the current workspace"""
        await self.send({
            "type": "term_create",
            "project": self.project,
            "workspace": self.workspace
        })
        msg = await self.recv_until("term_created")
        if msg:
            self.term_ids.append(msg["term_id"])
            self.outputs[msg["term_id"]] = ""
            print(f"[OK] Created terminal: {msg['term_id'][:8]}, cwd: {msg['cwd']}")
            return msg["term_id"]
        return None

    async def send_input(self, term_id, text):
        """Send input to a specific terminal"""
        data_b64 = base64.b64encode(text.encode()).decode()
        await self.send({
            "type": "input",
            "term_id": term_id,
            "data_b64": data_b64
        })

    async def wait_for_output(self, term_id, expected, timeout=5):
        """Wait for expected string in terminal output"""
        deadline = asyncio.get_event_loop().time() + timeout
        while asyncio.get_event_loop().time() < deadline:
            if expected in self.outputs.get(term_id, ""):
                return True
            await self.recv_until("output", term_id, timeout=0.5)
        return False

    async def close_terminal(self, term_id):
        """Close a terminal"""
        await self.send({"type": "term_close", "term_id": term_id})
        msg = await self.recv_until("term_closed")
        if msg and msg.get("term_id") == term_id:
            self.term_ids.remove(term_id)
            print(f"[OK] Closed terminal: {term_id[:8]}")
            return True
        return False

    async def close(self):
        if self.ws:
            await self.ws.close()


async def main():
    print("=" * 50)
    print("TidyFlow Multi-Terminal Smoke Test")
    print("=" * 50)

    tester = TerminalTester()

    try:
        # 1. Connect
        default_term = await tester.connect()

        # 2. Setup workspace
        if not await tester.setup_workspace():
            print("\n[SKIP] Cannot run full test without workspace")
            print("Run: scripts/workspace-demo.sh first")
            await tester.close()
            return 1

        # 3. Select workspace (this replaces default terminal)
        await tester.send({
            "type": "select_workspace",
            "project": tester.project,
            "workspace": tester.workspace
        })
        msg = await tester.recv_until("selected_workspace")
        if msg:
            # Update term_ids - old default is gone, new one created
            tester.term_ids = [msg["session_id"]]
            tester.outputs = {msg["session_id"]: ""}
            print(f"[OK] Selected workspace, new term: {msg['session_id'][:8]}")

        term1 = tester.term_ids[0]

        # 4. Create second terminal
        term2 = await tester.create_terminal()
        if not term2:
            print("[FAIL] Failed to create second terminal")
            await tester.close()
            return 1

        # 5. Wait for shells to initialize
        await asyncio.sleep(1)

        # Clear output buffers
        tester.outputs[term1] = ""
        tester.outputs[term2] = ""

        # 6. Send echo A to term1
        print("\n[TEST] Sending 'echo MARKER_A' to term1...")
        await tester.send_input(term1, "echo MARKER_A\n")
        await asyncio.sleep(0.5)

        # 7. Send echo B to term2
        print("[TEST] Sending 'echo MARKER_B' to term2...")
        await tester.send_input(term2, "echo MARKER_B\n")
        await asyncio.sleep(0.5)

        # 8. Collect output
        for _ in range(20):
            await tester.recv_until("output", timeout=0.2)

        # 9. Verify isolation
        print("\n[VERIFY] Checking output isolation...")

        term1_has_A = "MARKER_A" in tester.outputs[term1]
        term1_has_B = "MARKER_B" in tester.outputs[term1]
        term2_has_A = "MARKER_A" in tester.outputs[term2]
        term2_has_B = "MARKER_B" in tester.outputs[term2]

        print(f"  term1 output contains MARKER_A: {term1_has_A}")
        print(f"  term1 output contains MARKER_B: {term1_has_B}")
        print(f"  term2 output contains MARKER_A: {term2_has_A}")
        print(f"  term2 output contains MARKER_B: {term2_has_B}")

        isolation_ok = term1_has_A and not term1_has_B and term2_has_B and not term2_has_A

        if not isolation_ok:
            print("\n[FAIL] Output isolation failed!")
            await tester.close()
            return 1

        print("[OK] Output isolation verified!")

        # 10. Test pwd in both terminals
        print("\n[TEST] Verifying cwd with pwd...")
        tester.outputs[term1] = ""
        tester.outputs[term2] = ""

        await tester.send_input(term1, "pwd\n")
        await tester.send_input(term2, "pwd\n")
        await asyncio.sleep(0.5)

        for _ in range(20):
            await tester.recv_until("output", timeout=0.2)

        # Both should show workspace path
        print(f"  term1 pwd output: {tester.outputs[term1][:100]}...")
        print(f"  term2 pwd output: {tester.outputs[term2][:100]}...")

        # 11. Close terminals
        print("\n[TEST] Closing terminals...")
        await tester.close_terminal(term2)
        await tester.close_terminal(term1)

        print("\n" + "=" * 50)
        print("MULTI TERM SMOKE PASSED")
        print("=" * 50)

        await tester.close()
        return 0

    except Exception as e:
        print(f"\n[FAIL] Error: {e}")
        import traceback
        traceback.print_exc()
        await tester.close()
        return 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
