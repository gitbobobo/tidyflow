#!/usr/bin/env bash
set -euo pipefail

# Smoke test for WebSocket terminal server
# Tests connection, hello message, input/output, resize, and exit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_URL="${WS_URL:-ws://127.0.0.1:47999/ws}"
TIMEOUT="${TIMEOUT:-10}"

echo "=== WebSocket Terminal Smoke Test ==="
echo "Target: $WS_URL"
echo "Timeout: ${TIMEOUT}s"
echo ""

# Use Python for WebSocket testing (more portable than websocat)
python3 - <<'PYTHON_SCRIPT'
import asyncio
import websockets
import json
import base64
import sys
import os
from datetime import datetime

WS_URL = os.environ.get('WS_URL', 'ws://127.0.0.1:47999/ws')
TIMEOUT = int(os.environ.get('TIMEOUT', '10'))

class Colors:
    GREEN = '\033[92m'
    RED = '\033[91m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    RESET = '\033[0m'

def log(msg, color=None):
    timestamp = datetime.now().strftime('%H:%M:%S.%f')[:-3]
    if color:
        print(f"{color}[{timestamp}] {msg}{Colors.RESET}")
    else:
        print(f"[{timestamp}] {msg}")

def success(msg):
    log(f"✓ {msg}", Colors.GREEN)

def error(msg):
    log(f"✗ {msg}", Colors.RED)

def info(msg):
    log(f"→ {msg}", Colors.BLUE)

async def run_smoke_test():
    try:
        info(f"Connecting to {WS_URL}...")

        async with websockets.connect(WS_URL, ping_interval=None) as ws:
            success("Connected to WebSocket server")

            # Step 1: Wait for and validate "hello" message
            info("Waiting for 'hello' message...")
            try:
                hello_msg = await asyncio.wait_for(ws.recv(), timeout=TIMEOUT)
                hello_data = json.loads(hello_msg)

                if hello_data.get('type') == 'hello':
                    success(f"Received 'hello' message: {hello_data}")
                else:
                    error(f"Expected 'hello' message, got: {hello_data}")
                    return False
            except asyncio.TimeoutError:
                error("Timeout waiting for 'hello' message")
                return False

            # Step 2: Send "input" message with base64-encoded "ls\n"
            info("Sending 'ls' command...")
            ls_command = base64.b64encode(b"ls\n").decode('utf-8')
            input_msg = json.dumps({
                "type": "input",
                "data_b64": ls_command
            })
            await ws.send(input_msg)
            success("Sent 'input' message with 'ls' command")

            # Step 3: Wait for "output" messages
            info("Waiting for 'output' messages...")
            output_received = False
            output_count = 0

            try:
                for _ in range(10):  # Try to receive up to 10 messages
                    msg = await asyncio.wait_for(ws.recv(), timeout=2)
                    data = json.loads(msg)

                    if data.get('type') == 'output':
                        output_count += 1
                        output_data = base64.b64decode(data.get('data_b64', '')).decode('utf-8', errors='replace')
                        info(f"Received output ({len(output_data)} bytes): {output_data[:50]}...")
                        output_received = True
                    elif data.get('type') == 'exit':
                        info("Received early 'exit' message (shell may have closed)")
                        break
            except asyncio.TimeoutError:
                pass  # No more messages, continue

            if output_received:
                success(f"Received {output_count} 'output' message(s)")
            else:
                error("No 'output' messages received")
                return False

            # Step 4: Send "resize" message
            info("Sending 'resize' message (120x30)...")
            resize_msg = json.dumps({
                "type": "resize",
                "cols": 120,
                "rows": 30
            })
            await ws.send(resize_msg)
            success("Sent 'resize' message")

            # Give server time to process resize
            await asyncio.sleep(0.5)

            # Step 5: Send "input" message with base64-encoded "exit\n"
            info("Sending 'exit' command...")
            exit_command = base64.b64encode(b"exit\n").decode('utf-8')
            exit_input_msg = json.dumps({
                "type": "input",
                "data_b64": exit_command
            })
            await ws.send(exit_input_msg)
            success("Sent 'exit' command")

            # Step 6: Wait for "exit" message
            info("Waiting for 'exit' message...")
            exit_received = False

            try:
                for _ in range(5):  # Try to receive up to 5 messages
                    msg = await asyncio.wait_for(ws.recv(), timeout=3)
                    data = json.loads(msg)

                    if data.get('type') == 'exit':
                        exit_code = data.get('code', 'unknown')
                        success(f"Received 'exit' message with code: {exit_code}")
                        exit_received = True
                        break
                    elif data.get('type') == 'output':
                        # May receive output before exit
                        output_data = base64.b64decode(data.get('data_b64', '')).decode('utf-8', errors='replace')
                        info(f"Received output before exit: {output_data[:50]}...")
            except asyncio.TimeoutError:
                error("Timeout waiting for 'exit' message")
                return False

            if not exit_received:
                error("Did not receive 'exit' message")
                return False

            success("All smoke test steps completed successfully!")
            return True

    except websockets.exceptions.WebSocketException as e:
        error(f"WebSocket error: {e}")
        return False
    except ConnectionRefusedError:
        error(f"Connection refused - is the server running at {WS_URL}?")
        return False
    except Exception as e:
        error(f"Unexpected error: {e}")
        import traceback
        traceback.print_exc()
        return False

async def main():
    print("")
    result = await run_smoke_test()
    print("")

    if result:
        print(f"{Colors.GREEN}{'='*50}")
        print("SMOKE TEST PASSED ✓")
        print(f"{'='*50}{Colors.RESET}")
        sys.exit(0)
    else:
        print(f"{Colors.RED}{'='*50}")
        print("SMOKE TEST FAILED ✗")
        print(f"{'='*50}{Colors.RESET}")
        sys.exit(1)

if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print(f"\n{Colors.YELLOW}Test interrupted by user{Colors.RESET}")
        sys.exit(130)
PYTHON_SCRIPT
