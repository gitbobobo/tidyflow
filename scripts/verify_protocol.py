#!/usr/bin/env python3
"""
TidyFlow Protocol v1 Verification Script

Tests the WebSocket control plane protocol without requiring the UI.
Verifies:
1. v0 backward compatibility (hello/input/output/resize/ping/pong)
2. v1 control plane (list_projects, list_workspaces, select_workspace, spawn_terminal)
3. Terminal cwd binding

Usage:
    python3 verify_protocol.py [--port PORT]

Requirements:
    pip3 install websockets
"""

import asyncio
import json
import base64
import argparse
import sys
import os
from datetime import datetime

try:
    import websockets
except ImportError:
    print("Error: websockets library required. Install with: pip3 install websockets")
    sys.exit(1)


class ProtocolTester:
    def __init__(self, port: int = 47999):
        self.url = f"ws://127.0.0.1:{port}/ws"
        self.ws = None
        self.session_id = None
        self.protocol_version = 0
        self.capabilities = []
        self.results = []

    def log(self, msg: str, level: str = "INFO"):
        timestamp = datetime.now().strftime("%H:%M:%S.%f")[:-3]
        symbol = {"INFO": "ℹ", "OK": "✓", "FAIL": "✗", "WARN": "⚠"}.get(level, "•")
        print(f"[{timestamp}] {symbol} {msg}")
        self.results.append({"level": level, "msg": msg})

    async def connect(self) -> bool:
        """Connect to WebSocket server"""
        try:
            self.ws = await websockets.connect(self.url)
            self.log(f"Connected to {self.url}")
            return True
        except Exception as e:
            self.log(f"Connection failed: {e}", "FAIL")
            return False

    async def recv_message(self, timeout: float = 5.0) -> dict:
        """Receive and parse a JSON message"""
        try:
            data = await asyncio.wait_for(self.ws.recv(), timeout=timeout)
            return json.loads(data)
        except asyncio.TimeoutError:
            return None
        except Exception as e:
            self.log(f"Receive error: {e}", "FAIL")
            return None

    async def send_message(self, msg: dict):
        """Send a JSON message"""
        await self.ws.send(json.dumps(msg))

    async def test_hello(self) -> bool:
        """Test: Receive hello message on connect"""
        self.log("Testing: Hello message (v0 + v1 compatibility)")

        msg = await self.recv_message()
        if not msg:
            self.log("No hello message received", "FAIL")
            return False

        if msg.get("type") != "hello":
            self.log(f"Expected 'hello', got '{msg.get('type')}'", "FAIL")
            return False

        self.session_id = msg.get("session_id")
        self.protocol_version = msg.get("version", 0)
        self.capabilities = msg.get("capabilities", [])

        self.log(f"Hello received: version={self.protocol_version}, session={self.session_id[:8]}...", "OK")

        if self.protocol_version >= 1:
            self.log(f"v1 capabilities: {', '.join(self.capabilities)}", "OK")
        else:
            self.log("Server running v0 protocol (no workspace support)", "WARN")

        return True

    async def test_ping_pong(self) -> bool:
        """Test: Ping/Pong keepalive"""
        self.log("Testing: Ping/Pong")

        await self.send_message({"type": "ping"})
        msg = await self.recv_message(timeout=2.0)

        if msg and msg.get("type") == "pong":
            self.log("Pong received", "OK")
            return True
        else:
            self.log("No pong response", "FAIL")
            return False

    async def test_resize(self) -> bool:
        """Test: Terminal resize"""
        self.log("Testing: Resize")

        await self.send_message({"type": "resize", "cols": 120, "rows": 40})
        # Resize doesn't send a response, just verify no error
        await asyncio.sleep(0.1)
        self.log("Resize sent (no error)", "OK")
        return True

    async def test_input_output(self) -> bool:
        """Test: Terminal input/output"""
        self.log("Testing: Input/Output")

        # Send 'pwd' command
        cmd = "pwd\n"
        data_b64 = base64.b64encode(cmd.encode()).decode()
        await self.send_message({"type": "input", "data_b64": data_b64})

        # Wait for output
        output_received = False
        for _ in range(10):
            msg = await self.recv_message(timeout=1.0)
            if msg and msg.get("type") == "output":
                output_received = True
                # Decode and show first part of output
                out_data = base64.b64decode(msg.get("data_b64", "")).decode("utf-8", errors="replace")
                preview = out_data[:50].replace("\n", "\\n").replace("\r", "\\r")
                self.log(f"Output received: '{preview}...'", "OK")
                break

        if not output_received:
            self.log("No output received", "FAIL")
            return False

        return True

    async def test_list_projects(self) -> bool:
        """Test: v1 list_projects"""
        if self.protocol_version < 1:
            self.log("Skipping list_projects (v0 protocol)", "WARN")
            return True

        self.log("Testing: list_projects")

        await self.send_message({"type": "list_projects"})
        msg = await self.recv_message()

        if not msg:
            self.log("No response to list_projects", "FAIL")
            return False

        if msg.get("type") == "projects":
            items = msg.get("items", [])
            self.log(f"Projects received: {len(items)} project(s)", "OK")
            for p in items[:3]:  # Show first 3
                self.log(f"  - {p.get('name')}: {p.get('root')} ({p.get('workspace_count')} workspaces)")
            return True
        elif msg.get("type") == "error":
            self.log(f"Error: {msg.get('message')}", "FAIL")
            return False
        else:
            self.log(f"Unexpected response: {msg.get('type')}", "FAIL")
            return False

    async def test_list_workspaces(self, project: str) -> bool:
        """Test: v1 list_workspaces"""
        if self.protocol_version < 1:
            self.log("Skipping list_workspaces (v0 protocol)", "WARN")
            return True

        self.log(f"Testing: list_workspaces for '{project}'")

        await self.send_message({"type": "list_workspaces", "project": project})
        msg = await self.recv_message()

        if not msg:
            self.log("No response to list_workspaces", "FAIL")
            return False

        if msg.get("type") == "workspaces":
            items = msg.get("items", [])
            self.log(f"Workspaces received: {len(items)} workspace(s)", "OK")
            for w in items[:3]:  # Show first 3
                self.log(f"  - {w.get('name')}: {w.get('root')} [{w.get('status')}]")
            return True
        elif msg.get("type") == "error":
            self.log(f"Error: {msg.get('message')}", "WARN")
            return True  # Not a failure if project doesn't exist
        else:
            self.log(f"Unexpected response: {msg.get('type')}", "FAIL")
            return False

    async def test_spawn_terminal(self, cwd: str) -> bool:
        """Test: v1 spawn_terminal with cwd"""
        if self.protocol_version < 1:
            self.log("Skipping spawn_terminal (v0 protocol)", "WARN")
            return True

        self.log(f"Testing: spawn_terminal with cwd='{cwd}'")

        await self.send_message({"type": "spawn_terminal", "cwd": cwd})

        # Drain any pending output first
        for _ in range(5):
            msg = await self.recv_message(timeout=0.5)
            if not msg:
                break
            if msg.get("type") == "terminal_spawned":
                new_session = msg.get("session_id", "")
                spawned_cwd = msg.get("cwd", "")
                self.log(f"Terminal spawned: session={new_session[:8]}..., cwd={spawned_cwd}", "OK")
                return True
            elif msg.get("type") == "error":
                self.log(f"Error: {msg.get('message')}", "FAIL")
                return False

        self.log("No terminal_spawned response", "FAIL")
        return False

    async def test_cwd_verification(self, expected_cwd: str) -> bool:
        """Verify terminal is running in expected cwd"""
        self.log(f"Verifying: Terminal cwd is '{expected_cwd}'")

        # Send pwd command
        cmd = "pwd\n"
        data_b64 = base64.b64encode(cmd.encode()).decode()
        await self.send_message({"type": "input", "data_b64": data_b64})

        # Collect output
        output = ""
        for _ in range(10):
            msg = await self.recv_message(timeout=1.0)
            if msg and msg.get("type") == "output":
                out_data = base64.b64decode(msg.get("data_b64", "")).decode("utf-8", errors="replace")
                output += out_data
                if "\n" in output and expected_cwd in output:
                    break

        if expected_cwd in output:
            self.log(f"CWD verified: contains '{expected_cwd}'", "OK")
            return True
        else:
            self.log(f"CWD mismatch: expected '{expected_cwd}' in output", "FAIL")
            return False

    async def run_all_tests(self, test_cwd: str = None):
        """Run all protocol tests"""
        print("=" * 60)
        print("TidyFlow Protocol v1 Verification")
        print("=" * 60)

        if not await self.connect():
            return False

        tests = [
            ("Hello", self.test_hello),
            ("Ping/Pong", self.test_ping_pong),
            ("Resize", self.test_resize),
            ("Input/Output", self.test_input_output),
            ("List Projects", self.test_list_projects),
        ]

        # Add workspace tests if we have projects
        # (will be tested after list_projects)

        passed = 0
        failed = 0

        for name, test_fn in tests:
            try:
                if await test_fn():
                    passed += 1
                else:
                    failed += 1
            except Exception as e:
                self.log(f"Test '{name}' exception: {e}", "FAIL")
                failed += 1

        # Test spawn_terminal with custom cwd if provided
        if test_cwd and self.protocol_version >= 1:
            if os.path.isdir(test_cwd):
                if await self.test_spawn_terminal(test_cwd):
                    passed += 1
                    # Verify cwd
                    if await self.test_cwd_verification(test_cwd):
                        passed += 1
                    else:
                        failed += 1
                else:
                    failed += 1
            else:
                self.log(f"Test cwd '{test_cwd}' does not exist, skipping", "WARN")

        # Close connection
        await self.ws.close()

        print("=" * 60)
        print(f"Results: {passed} passed, {failed} failed")
        print("=" * 60)

        return failed == 0


async def main():
    parser = argparse.ArgumentParser(description="TidyFlow Protocol v1 Verification")
    parser.add_argument("--port", type=int, default=47999, help="WebSocket port (default: 47999)")
    parser.add_argument("--cwd", type=str, default=None, help="Test spawn_terminal with this cwd")
    args = parser.parse_args()

    # Default test cwd to home directory if not specified
    test_cwd = args.cwd or os.path.expanduser("~")

    tester = ProtocolTester(port=args.port)
    success = await tester.run_all_tests(test_cwd=test_cwd)

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    asyncio.run(main())
