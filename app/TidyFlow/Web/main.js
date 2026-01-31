/**
 * TidyFlow Terminal - Main JavaScript
 * Connects xterm.js to Rust core via WebSocket (Protocol v1.1 - Multi-Terminal)
 */

(function() {
    'use strict';

    // Transport interface
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

    // State
    let transport = null;
    let protocolVersion = 0;
    let capabilities = [];

    // Workspace state
    let projects = [];
    let workspaces = [];
    let currentProject = null;
    let currentWorkspace = null;

    // Multi-terminal state (v1.2: with workspace binding)
    let tabs = new Map(); // term_id -> { term, fitAddon, container, tabEl, cwd, project, workspace }
    let activeTermId = null;
    let tabCounter = 0;

    // DOM elements
    let tabBar = null;
    let terminalsContainer = null;
    let workspaceInfo = null;

    function initUI() {
        tabBar = document.getElementById('tab-bar');
        terminalsContainer = document.getElementById('terminals');
        workspaceInfo = document.getElementById('workspace-info');

        // New tab button
        document.getElementById('tab-new').addEventListener('click', () => {
            if (currentProject && currentWorkspace) {
                createTerminal(currentProject, currentWorkspace);
            } else {
                console.warn('No workspace selected');
            }
        });
    }

    function createTerminalInstance(termId, cwd, project, workspace) {
        tabCounter++;

        // Create terminal
        const term = new Terminal({
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

        // Load addons
        const fitAddon = new FitAddon.FitAddon();
        term.loadAddon(fitAddon);

        try {
            const webLinksAddon = new WebLinksAddon.WebLinksAddon();
            term.loadAddon(webLinksAddon);
        } catch (e) {
            console.warn('WebLinks addon failed:', e.message);
        }

        try {
            const webglAddon = new WebglAddon.WebglAddon();
            webglAddon.onContextLoss(() => webglAddon.dispose());
            term.loadAddon(webglAddon);
        } catch (e) {
            console.warn('WebGL addon failed:', e.message);
        }

        // Create container
        const container = document.createElement('div');
        container.className = 'terminal-container';
        container.id = 'term-' + termId;
        terminalsContainer.appendChild(container);

        // Open terminal
        term.open(container);

        // Create tab element
        const tabEl = document.createElement('div');
        tabEl.className = 'tab';
        tabEl.dataset.termId = termId;

        const title = document.createElement('span');
        title.className = 'tab-title';
        // v1.2: Show workspace name in tab title
        title.textContent = workspace || 'Tab ' + tabCounter;
        tabEl.appendChild(title);

        const closeBtn = document.createElement('span');
        closeBtn.className = 'tab-close';
        closeBtn.textContent = '\u00d7';
        closeBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            closeTerminal(termId);
        });
        tabEl.appendChild(closeBtn);

        tabEl.addEventListener('click', () => {
            switchToTab(termId);
        });

        // Insert before the + button
        const newBtn = document.getElementById('tab-new');
        tabBar.insertBefore(tabEl, newBtn);

        // Handle input
        term.onData((data) => {
            if (transport && transport.isConnected) {
                const encoder = new TextEncoder();
                const bytes = encoder.encode(data);
                const msg = JSON.stringify({
                    type: 'input',
                    term_id: termId,
                    data_b64: encodeBase64(bytes)
                });
                transport.send(msg);
            }
        });

        // Handle resize
        const resizeObserver = new ResizeObserver(() => {
            if (fitAddon && activeTermId === termId) {
                fitAddon.fit();
                sendResize(termId, term.cols, term.rows);
            }
        });
        resizeObserver.observe(container);

        // Store tab info (v1.2: with workspace binding)
        tabs.set(termId, {
            term,
            fitAddon,
            container,
            tabEl,
            cwd: cwd || '',
            project: project || '',
            workspace: workspace || '',
            resizeObserver
        });

        return { term, fitAddon, container, tabEl };
    }

    function switchToTab(termId) {
        if (!tabs.has(termId)) return;

        // Deactivate current
        if (activeTermId && tabs.has(activeTermId)) {
            const current = tabs.get(activeTermId);
            current.container.classList.remove('active');
            current.tabEl.classList.remove('active');
        }

        // Activate new
        const tab = tabs.get(termId);
        tab.container.classList.add('active');
        tab.tabEl.classList.add('active');
        activeTermId = termId;

        // Fit and focus
        setTimeout(() => {
            tab.fitAddon.fit();
            tab.term.focus();
            sendResize(termId, tab.term.cols, tab.term.rows);
        }, 0);

        // Notify Swift
        notifySwift('tab_switched', { term_id: termId });
    }

    function closeTerminal(termId) {
        if (!tabs.has(termId)) return;

        // Send close request to server
        if (transport && transport.isConnected) {
            transport.send(JSON.stringify({
                type: 'term_close',
                term_id: termId
            }));
        }
    }

    function removeTab(termId) {
        if (!tabs.has(termId)) return;

        const tab = tabs.get(termId);

        // Clean up
        tab.resizeObserver.disconnect();
        tab.term.dispose();
        tab.container.remove();
        tab.tabEl.remove();
        tabs.delete(termId);

        // Switch to another tab if this was active
        if (activeTermId === termId) {
            activeTermId = null;
            const remaining = Array.from(tabs.keys());
            if (remaining.length > 0) {
                switchToTab(remaining[0]);
            }
        }
    }

    function sendResize(termId, cols, rows) {
        if (transport && transport.isConnected) {
            const msg = JSON.stringify({
                type: 'resize',
                term_id: termId,
                cols: cols,
                rows: rows
            });
            transport.send(msg);
        }
    }

    // v1.1 Control Plane
    function sendControlMessage(msg) {
        if (transport && transport.isConnected) {
            transport.send(JSON.stringify(msg));
        }
    }

    function listProjects() {
        sendControlMessage({ type: 'list_projects' });
    }

    function listWorkspaces(project) {
        sendControlMessage({ type: 'list_workspaces', project });
    }

    function selectWorkspace(project, workspace) {
        currentProject = project;
        currentWorkspace = workspace;
        updateWorkspaceInfo();
        sendControlMessage({ type: 'select_workspace', project, workspace });
    }

    function createTerminal(project, workspace) {
        sendControlMessage({ type: 'term_create', project, workspace });
    }

    function listTerminals() {
        sendControlMessage({ type: 'term_list' });
    }

    // v1.3 File Operations API
    function sendFileList(project, workspace, path) {
        sendControlMessage({ type: 'file_list', project, workspace, path: path || '.' });
    }

    function sendFileRead(project, workspace, path) {
        sendControlMessage({ type: 'file_read', project, workspace, path });
    }

    function sendFileWrite(project, workspace, path, content_b64) {
        sendControlMessage({ type: 'file_write', project, workspace, path, content_b64 });
    }

    function updateWorkspaceInfo() {
        if (workspaceInfo) {
            if (currentProject && currentWorkspace) {
                workspaceInfo.textContent = currentProject + '/' + currentWorkspace;
            } else {
                workspaceInfo.textContent = '';
            }
        }
    }

    function handleMessage(data) {
        try {
            const msg = JSON.parse(data);

            switch (msg.type) {
                case 'hello': {
                    protocolVersion = msg.version || 0;
                    capabilities = msg.capabilities || [];

                    // Create default terminal tab (no workspace binding)
                    const { term } = createTerminalInstance(msg.session_id, null, null, null);
                    switchToTab(msg.session_id);

                    term.writeln('\x1b[90m[TidyFlow Terminal]\x1b[0m');
                    term.writeln('\x1b[32m[Connected]\x1b[0m Shell: ' + msg.shell + ', Session: ' + msg.session_id.substring(0, 8));
                    if (protocolVersion >= 1) {
                        term.writeln('\x1b[90mProtocol v' + protocolVersion + ' | Capabilities: ' + capabilities.join(', ') + '\x1b[0m');
                    }
                    term.writeln('');

                    // Send initial resize
                    const tab = tabs.get(msg.session_id);
                    if (tab) {
                        tab.fitAddon.fit();
                        sendResize(msg.session_id, tab.term.cols, tab.term.rows);
                    }

                    notifySwift('hello', {
                        session_id: msg.session_id,
                        version: protocolVersion,
                        capabilities
                    });
                    break;
                }

                case 'output': {
                    const termId = msg.term_id || activeTermId;
                    if (termId && tabs.has(termId)) {
                        const bytes = decodeBase64(msg.data_b64);
                        tabs.get(termId).term.write(bytes);
                    }
                    break;
                }

                case 'exit': {
                    const termId = msg.term_id || activeTermId;
                    if (termId && tabs.has(termId)) {
                        const tab = tabs.get(termId);
                        tab.term.writeln('');
                        tab.term.writeln('\x1b[33m[Shell exited with code ' + msg.code + ']\x1b[0m');
                    }
                    break;
                }

                case 'pong':
                    break;

                case 'projects':
                    projects = msg.items || [];
                    notifySwift('projects', { items: projects });
                    break;

                case 'workspaces':
                    workspaces = msg.items || [];
                    currentProject = msg.project;
                    updateWorkspaceInfo();
                    notifySwift('workspaces', { project: msg.project, items: workspaces });
                    break;

                case 'selected_workspace': {
                    currentProject = msg.project;
                    currentWorkspace = msg.workspace;
                    updateWorkspaceInfo();

                    // Notify editor of workspace change
                    if (window.tidyflowEditor) {
                        window.tidyflowEditor.setWorkspace(msg.project, msg.workspace, msg.root);
                    }

                    // v1.2: Do NOT clear existing tabs - support parallel workspaces
                    // Create new tab for this workspace
                    const { term } = createTerminalInstance(msg.session_id, msg.root, msg.project, msg.workspace);
                    switchToTab(msg.session_id);

                    term.writeln('\x1b[32m[Workspace: ' + msg.project + '/' + msg.workspace + ']\x1b[0m');
                    term.writeln('\x1b[90mRoot: ' + msg.root + '\x1b[0m');
                    term.writeln('\x1b[90mShell: ' + msg.shell + ', Session: ' + msg.session_id.substring(0, 8) + '\x1b[0m');
                    term.writeln('');

                    const tab = tabs.get(msg.session_id);
                    if (tab) {
                        tab.fitAddon.fit();
                        sendResize(msg.session_id, tab.term.cols, tab.term.rows);
                    }

                    notifySwift('workspace_selected', {
                        project: msg.project,
                        workspace: msg.workspace,
                        root: msg.root,
                        session_id: msg.session_id
                    });
                    break;
                }

                case 'terminal_spawned': {
                    // Legacy single-terminal spawn - v1.2: no longer clears tabs
                    const { term } = createTerminalInstance(msg.session_id, msg.cwd, null, null);
                    switchToTab(msg.session_id);

                    term.writeln('\x1b[32m[Terminal spawned]\x1b[0m');
                    term.writeln('\x1b[90mCWD: ' + msg.cwd + '\x1b[0m');
                    term.writeln('\x1b[90mShell: ' + msg.shell + ', Session: ' + msg.session_id.substring(0, 8) + '\x1b[0m');
                    term.writeln('');

                    const tab = tabs.get(msg.session_id);
                    if (tab) {
                        tab.fitAddon.fit();
                        sendResize(msg.session_id, tab.term.cols, tab.term.rows);
                    }

                    notifySwift('terminal_spawned', {
                        session_id: msg.session_id,
                        cwd: msg.cwd
                    });
                    break;
                }

                case 'terminal_killed':
                    removeTab(msg.session_id);
                    notifySwift('terminal_killed', { session_id: msg.session_id });
                    break;

                // v1.2: Multi-workspace responses
                case 'term_created': {
                    // v1.2: term_created now includes project/workspace
                    const { term } = createTerminalInstance(msg.term_id, msg.cwd, msg.project, msg.workspace);
                    switchToTab(msg.term_id);

                    term.writeln('\x1b[32m[New Terminal: ' + (msg.workspace || 'default') + ']\x1b[0m');
                    term.writeln('\x1b[90mCWD: ' + msg.cwd + '\x1b[0m');
                    term.writeln('\x1b[90mShell: ' + msg.shell + '\x1b[0m');
                    term.writeln('');

                    const tab = tabs.get(msg.term_id);
                    if (tab) {
                        tab.fitAddon.fit();
                        sendResize(msg.term_id, tab.term.cols, tab.term.rows);
                    }

                    notifySwift('term_created', {
                        term_id: msg.term_id,
                        project: msg.project,
                        workspace: msg.workspace,
                        cwd: msg.cwd
                    });
                    break;
                }

                case 'term_list':
                    notifySwift('term_list', { items: msg.items });
                    break;

                case 'term_closed':
                    removeTab(msg.term_id);
                    notifySwift('term_closed', { term_id: msg.term_id });
                    break;

                // v1.3: File operation responses
                case 'file_list_result':
                    if (window.tidyflowEditor) {
                        window.tidyflowEditor.handleFileList(msg.project, msg.workspace, msg.path, msg.items);
                    }
                    notifySwift('file_list', { project: msg.project, workspace: msg.workspace, items: msg.items });
                    break;

                case 'file_read_result':
                    if (window.tidyflowEditor) {
                        window.tidyflowEditor.handleFileRead(msg.project, msg.workspace, msg.path, msg.content_b64, msg.size);
                    }
                    notifySwift('file_read', { project: msg.project, workspace: msg.workspace, path: msg.path, size: msg.size });
                    break;

                case 'file_write_result':
                    if (window.tidyflowEditor) {
                        window.tidyflowEditor.handleFileWrite(msg.project, msg.workspace, msg.path, msg.success, msg.size);
                    }
                    notifySwift('file_write', { project: msg.project, workspace: msg.workspace, path: msg.path, success: msg.success });
                    break;

                case 'error':
                    if (activeTermId && tabs.has(activeTermId)) {
                        const tab = tabs.get(activeTermId);
                        tab.term.writeln('');
                        tab.term.writeln('\x1b[31m[Error: ' + msg.code + '] ' + msg.message + '\x1b[0m');
                    }
                    notifySwift('error', { code: msg.code, message: msg.message });
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

        console.log('Connecting to ' + wsURL);

        transport = new WebSocketTransport(wsURL, {
            onOpen: () => {
                notifySwift('connected');
            },
            onClose: () => {
                notifySwift('disconnected');
                // Show disconnected message in active terminal
                if (activeTermId && tabs.has(activeTermId)) {
                    tabs.get(activeTermId).term.writeln('\x1b[31m[Disconnected]\x1b[0m');
                }
            },
            onError: (e) => {
                notifySwift('error', { message: e.message || 'Connection failed' });
            },
            onMessage: handleMessage
        });

        transport.connect();
    }

    function reconnect() {
        if (activeTermId && tabs.has(activeTermId)) {
            tabs.get(activeTermId).term.writeln('\x1b[90mReconnecting...\x1b[0m');
        }
        connect();
    }

    // Initialize on load
    document.addEventListener('DOMContentLoaded', () => {
        initUI();
    });

    // Expose API for Swift
    window.tidyflow = {
        connect,
        reconnect,
        getActiveTermId: () => activeTermId,
        getProtocolVersion: () => protocolVersion,
        getCapabilities: () => capabilities,

        // v1 Control Plane API
        listProjects,
        listWorkspaces,
        selectWorkspace,

        // v1.2 Multi-workspace API
        createTerminal,
        listTerminals,
        closeTerminal,
        switchToTab,

        // v1.3 File Operations API
        sendFileList,
        sendFileRead,
        sendFileWrite,

        // State getters
        getProjects: () => projects,
        getWorkspaces: () => workspaces,
        getCurrentProject: () => currentProject,
        getCurrentWorkspace: () => currentWorkspace,
        getTabs: () => Array.from(tabs.keys()),

        // v1.2: Get tab info with workspace binding
        getTabInfo: (termId) => {
            const tab = tabs.get(termId);
            if (!tab) return null;
            return {
                term_id: termId,
                project: tab.project,
                workspace: tab.workspace,
                cwd: tab.cwd
            };
        },
        getAllTabsInfo: () => {
            return Array.from(tabs.entries()).map(([termId, tab]) => ({
                term_id: termId,
                project: tab.project,
                workspace: tab.workspace,
                cwd: tab.cwd
            }));
        },
    };
})();
