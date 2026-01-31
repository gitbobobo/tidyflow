/**
 * TidyFlow Terminal - Main JavaScript
 * Connects xterm.js to Rust core via WebSocket (Protocol v0)
 */

(function() {
    'use strict';

    // Transport interface - can be swapped for WKScriptMessageHandler bridge if WS fails
    class WebSocketTransport {
        constructor(url, callbacks) {
            this.url = url;
            this.callbacks = callbacks;
            this.ws = null;
        }

        connect() {
            try {
                this.ws = new WebSocket(this.url);
                this.ws.onopen = () => this.callbacks.onOpen();
                this.ws.onclose = () => this.callbacks.onClose();
                this.ws.onerror = (e) => this.callbacks.onError(e);
                this.ws.onmessage = (e) => this.callbacks.onMessage(e.data);
            } catch (err) {
                this.callbacks.onError(err);
            }
        }

        send(data) {
            if (this.ws && this.ws.readyState === WebSocket.OPEN) {
                this.ws.send(data);
            }
        }

        close() {
            if (this.ws) {
                this.ws.close();
            }
        }

        get isConnected() {
            return this.ws && this.ws.readyState === WebSocket.OPEN;
        }
    }

    // Base64 utilities
    function encodeBase64(uint8Array) {
        let binary = '';
        for (let i = 0; i < uint8Array.length; i++) {
            binary += String.fromCharCode(uint8Array[i]);
        }
        return btoa(binary);
    }

    function decodeBase64(base64) {
        const binary = atob(base64);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) {
            bytes[i] = binary.charCodeAt(i);
        }
        return bytes;
    }

    // Notify Swift of status changes
    function notifySwift(type, data) {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tidyflow) {
            window.webkit.messageHandlers.tidyflow.postMessage({ type, ...data });
        }
    }

    // Terminal instance
    let term = null;
    let fitAddon = null;
    let transport = null;
    let webglEnabled = false;
    let sessionId = null;

    function initTerminal() {
        term = new Terminal({
            cursorBlink: true,
            fontSize: 14,
            fontFamily: 'Menlo, Monaco, "Courier New", monospace',
            theme: {
                background: '#1e1e1e',
                foreground: '#d4d4d4',
                cursor: '#d4d4d4',
                cursorAccent: '#1e1e1e',
                selectionBackground: '#264f78',
            },
            allowProposedApi: true,
        });

        // Load fit addon (required)
        fitAddon = new FitAddon.FitAddon();
        term.loadAddon(fitAddon);

        // Load web links addon
        try {
            const webLinksAddon = new WebLinksAddon.WebLinksAddon();
            term.loadAddon(webLinksAddon);
        } catch (e) {
            console.warn('WebLinks addon failed:', e.message);
        }

        // Try WebGL addon (optional, fallback to DOM renderer)
        try {
            const webglAddon = new WebglAddon.WebglAddon();
            webglAddon.onContextLoss(() => {
                webglAddon.dispose();
                webglEnabled = false;
            });
            term.loadAddon(webglAddon);
            webglEnabled = true;
        } catch (e) {
            console.warn('WebGL addon failed, using DOM renderer:', e.message);
            webglEnabled = false;
        }

        // Open terminal
        const container = document.getElementById('terminal');
        term.open(container);
        fitAddon.fit();

        // Handle input
        term.onData((data) => {
            if (transport && transport.isConnected) {
                const encoder = new TextEncoder();
                const bytes = encoder.encode(data);
                const msg = JSON.stringify({
                    type: 'input',
                    data_b64: encodeBase64(bytes)
                });
                transport.send(msg);
            }
        });

        // Handle resize
        const resizeObserver = new ResizeObserver(() => {
            if (fitAddon) {
                fitAddon.fit();
                sendResize();
            }
        });
        resizeObserver.observe(container);

        term.writeln('\x1b[90m[TidyFlow Terminal]\x1b[0m');
        term.writeln('\x1b[90mWebGL: ' + (webglEnabled ? 'enabled' : 'disabled (DOM renderer)') + '\x1b[0m');
        term.writeln('');
    }

    function sendResize() {
        if (transport && transport.isConnected && term) {
            const msg = JSON.stringify({
                type: 'resize',
                cols: term.cols,
                rows: term.rows
            });
            transport.send(msg);
        }
    }

    function handleMessage(data) {
        try {
            const msg = JSON.parse(data);

            switch (msg.type) {
                case 'hello':
                    sessionId = msg.session_id;
                    term.writeln('\x1b[32m[Connected]\x1b[0m Shell: ' + msg.shell + ', Session: ' + msg.session_id.substring(0, 8));
                    term.writeln('');
                    // Send initial resize
                    sendResize();
                    break;

                case 'output':
                    if (msg.data_b64) {
                        const bytes = decodeBase64(msg.data_b64);
                        term.write(bytes);
                    }
                    break;

                case 'exit':
                    term.writeln('');
                    term.writeln('\x1b[33m[Shell exited with code ' + msg.code + ']\x1b[0m');
                    break;

                case 'pong':
                    // Keepalive response, ignore
                    break;

                default:
                    console.warn('Unknown message type:', msg.type);
            }
        } catch (e) {
            console.error('Failed to parse message:', e);
        }
    }

    function connect() {
        const wsURL = window.TIDYFLOW_WS_URL || 'ws://127.0.0.1:47999/ws';

        if (transport) {
            transport.close();
        }

        term.writeln('\x1b[90mConnecting to ' + wsURL + '...\x1b[0m');

        transport = new WebSocketTransport(wsURL, {
            onOpen: () => {
                notifySwift('connected');
            },
            onClose: () => {
                notifySwift('disconnected');
                term.writeln('');
                term.writeln('\x1b[31m[Disconnected]\x1b[0m');
            },
            onError: (e) => {
                notifySwift('error', { message: e.message || 'Connection failed' });
                term.writeln('\x1b[31m[Connection error]\x1b[0m');
            },
            onMessage: handleMessage
        });

        transport.connect();
    }

    function reconnect() {
        term.writeln('');
        term.writeln('\x1b[90mReconnecting...\x1b[0m');
        connect();
    }

    // Initialize on load
    document.addEventListener('DOMContentLoaded', () => {
        initTerminal();
    });

    // Expose API for Swift
    window.tidyflow = {
        connect,
        reconnect,
        getSessionId: () => sessionId,
        isWebGLEnabled: () => webglEnabled,
    };
})();
