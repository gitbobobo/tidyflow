/**
 * TidyFlow Mobile Terminal - xterm.js 初始化与 Native 桥接
 * 数据流:
 *   输出: Rust Core PTY → WSClient → MobileAppState → MobileBridge → xterm.js
 *   输入: xterm.js(onData) → MobileBridge → MobileAppState → WSClient → Rust Core PTY
 */
(function() {
    'use strict';

    let term = null;
    let fitAddon = null;
    let isReady = false;
    let focusTimer = null;

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
                scheduleFocus(80);
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

    function focusTerminal() {
        if (!term) return;
        term.focus();
    }

    function scheduleFocus(delayMs) {
        if (focusTimer) {
            clearTimeout(focusTimer);
        }
        focusTimer = setTimeout(function() {
            focusTerminal();
        }, delayMs || 0);
    }

    // 统一发送输入到 Native，避免多入口分叉
    function sendTerminalData(data) {
        if (typeof data !== 'string' || data.length === 0) return;
        postToNative('terminal_data', { data: data });
    }

    // 初始化终端
    function initTerminal() {
        const container = document.getElementById('terminal-container');
        if (!container) return;

        term = new Terminal({
            cursorBlink: true,
            fontSize: 14,
            fontFamily: '"MesloLGS NF", "SF Mono", Menlo, Monaco, "Courier New", monospace',
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

        // iOS 输入兼容：
        // 1) 主路径：xterm onData
        // 2) 兜底：监听 helper textarea 的 input/composition，
        //    解决某些键盘布局下空格/符号 onData 不触发的问题
        let isComposing = false;
        let compositionJustEnded = false;
        let compositionEndData = '';
        let compositionDataSent = false;
        let pendingInputTimer = null;
        let lastOnDataTime = 0;
        let lastOnDataChar = '';
        const textarea = container.querySelector('textarea');

        if (textarea) {
            textarea.addEventListener('input', function(e) {
                const isInsertText = e.inputType === 'insertText' || e.inputType === 'insertCompositionText';
                if (!isInsertText || typeof e.data !== 'string' || e.data.length === 0) {
                    return;
                }
                if (isComposing || e.isComposing) {
                    return;
                }

                const inputData = e.data;
                const inputTime = Date.now();
                if (inputData === lastOnDataChar && (inputTime - lastOnDataTime) < 50) {
                    return;
                }

                if (pendingInputTimer) {
                    clearTimeout(pendingInputTimer);
                }
                pendingInputTimer = setTimeout(function() {
                    const checkTime = Date.now();
                    if (inputData === lastOnDataChar && (checkTime - lastOnDataTime) < 50) {
                        pendingInputTimer = null;
                        return;
                    }
                    sendTerminalData(inputData);
                    pendingInputTimer = null;
                }, 20);
            });

            textarea.addEventListener('compositionstart', function() {
                isComposing = true;
                compositionJustEnded = false;
                compositionEndData = '';
                compositionDataSent = false;
            });

            textarea.addEventListener('compositionend', function(e) {
                isComposing = false;
                compositionJustEnded = true;
                compositionEndData = e.data || '';
                compositionDataSent = false;

                setTimeout(function() {
                    if (!compositionDataSent && compositionEndData.length > 0) {
                        sendTerminalData(compositionEndData);
                    }
                    compositionJustEnded = false;
                    compositionEndData = '';
                }, 50);
            });
        }

        // 终端输入 → Native（主路径）
        term.onData(function(data) {
            lastOnDataTime = Date.now();
            lastOnDataChar = data;
            if (isComposing) {
                return;
            }
            if (compositionJustEnded) {
                compositionDataSent = true;
            }
            sendTerminalData(data);
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
            scheduleFocus(60);
        });

        // iOS 需要用户手势触发聚焦才能稳定弹出键盘
        // 区分点击与滑动：仅点击（移动距离 < 10px）时聚焦弹出键盘
        let touchStartX = 0;
        let touchStartY = 0;
        container.addEventListener('touchstart', function(e) {
            const t = e.touches[0];
            touchStartX = t.clientX;
            touchStartY = t.clientY;
        }, { passive: true });
        container.addEventListener('touchend', function(e) {
            const t = e.changedTouches[0];
            const dx = t.clientX - touchStartX;
            const dy = t.clientY - touchStartY;
            if (dx * dx + dy * dy < 100) {
                focusTerminal();
            }
        }, { passive: true });
        container.addEventListener('click', function() {
            focusTerminal();
        });

        window.addEventListener('focus', function() {
            scheduleFocus(60);
        });

        document.addEventListener('visibilitychange', function() {
            if (!document.hidden) {
                scheduleFocus(60);
            }
        });

        isReady = true;

        // 尝试初次聚焦；若被系统拦截，用户触摸后会再次聚焦
        scheduleFocus(120);

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
