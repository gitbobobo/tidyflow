/**
 * TidyFlow Mobile Terminal - xterm.js 初始化与 Native 桥接
 * 数据流: Rust Core PTY ↔ WSClient ↔ MobileAppState ↔ MobileBridge ↔ xterm.js
 */
(function() {
    'use strict';

    let term = null;
    let fitAddon = null;
    let isReady = false;

    // xterm.js 暗色主题（同 macOS 端）
    const THEME = {
        background: '#1e1e1e',
        foreground: '#d4d4d4',
        cursor: '#aeafad',
        cursorAccent: '#1e1e1e',
        selectionBackground: 'rgba(255, 255, 255, 0.3)',
        black: '#000000',
        red: '#cd3131',
        green: '#0dbc79',
        yellow: '#e5e510',
        blue: '#2472c8',
        magenta: '#bc3fbc',
        cyan: '#11a8cd',
        white: '#e5e5e5',
        brightBlack: '#666666',
        brightRed: '#f14c4c',
        brightGreen: '#23d18b',
        brightYellow: '#f5f543',
        brightBlue: '#3b8eea',
        brightMagenta: '#d670d6',
        brightCyan: '#29b8db',
        brightWhite: '#ffffff'
    };

    // Native 桥接对象
    window.tidyflowMobile = {
        // Native → JS: Base64 编码事件
        receiveBase64: function(type, base64Payload) {
            try {
                const jsonStr = atob(base64Payload);
                const payload = JSON.parse(jsonStr);
                handleNativeEvent(type, payload);
            } catch (e) {
                console.error('[MobileBridge] Base64/Parse error:', e);
            }
        }
    };

    // 处理 Native 发来的事件
    function handleNativeEvent(type, payload) {
        switch (type) {
            case 'write_output':
                // 写入终端输出（Base64 编码的二进制数据）
                if (term && payload.base64) {
                    const bytes = Uint8Array.from(atob(payload.base64), c => c.charCodeAt(0));
                    term.write(bytes);
                }
                break;

            case 'resize':
                // Native 通知 resize
                if (fitAddon) {
                    fitAddon.fit();
                }
                break;

            case 'write_input':
                // Native 直接写入输入（特殊键等）
                if (term && payload.data) {
                    term.write(payload.data);
                }
                break;

            default:
                console.log('[MobileBridge] Unknown event:', type);
        }
    }

    // JS → Native: 发送消息
    function postToNative(type, payload) {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tidyflowMobile) {
            window.webkit.messageHandlers.tidyflowMobile.postMessage({
                type: type,
                ...payload
            });
        }
    }

    // 初始化终端
    function initTerminal() {
        const container = document.getElementById('terminal-container');
        if (!container) return;

        term = new Terminal({
            cursorBlink: true,
            fontSize: 14,
            fontFamily: '"SF Mono", Menlo, Monaco, "Courier New", monospace',
            scrollback: 5000,
            theme: THEME,
            allowProposedApi: true,
            convertEol: false,
            windowOptions: { setWinSizePixels: false }
        });

        fitAddon = new FitAddon.FitAddon();
        term.loadAddon(fitAddon);

        // Web Links addon - 点击链接通知 Native 打开
        const webLinksAddon = new WebLinksAddon.WebLinksAddon(function(event, uri) {
            event.preventDefault();
            postToNative('open_url', { url: uri });
        });
        term.loadAddon(webLinksAddon);

        // Unicode11 addon
        const unicode11Addon = new Unicode11Addon.Unicode11Addon();
        term.loadAddon(unicode11Addon);
        term.unicode.activeVersion = '11';

        term.open(container);
        fitAddon.fit();

        // 终端输入 → Native
        term.onData(function(data) {
            postToNative('terminal_data', { data: data });
        });

        // 终端 resize → Native
        term.onResize(function(size) {
            postToNative('terminal_resized', { cols: size.cols, rows: size.rows });
        });

        // 监听窗口 resize
        window.addEventListener('resize', function() {
            if (fitAddon) {
                fitAddon.fit();
            }
        });

        isReady = true;

        // 通知 Native 终端已就绪
        const dims = { cols: term.cols, rows: term.rows };
        postToNative('ready', dims);
    }

    // 页面加载完成后初始化
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initTerminal);
    } else {
        initTerminal();
    }
})();