/**
 * TidyFlow Terminal - Main JavaScript
 * Workspace-scoped tabs with unified Editor + Terminal tabs
 * Protocol v1.3 - Multi-Terminal + File Operations
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

    // Projects/Workspaces state
    let projects = [];
    let workspacesMap = new Map(); // project -> workspace[]
    let currentProject = null;
    let currentWorkspace = null;
    let currentWorkspaceRoot = null;

    // Workspace-scoped tabs (v2.0)
    // workspaceTabs: Map<workspaceKey, TabSet>
    // TabSet = { tabs: Map<tabId, TabInfo>, activeTabId, tabOrder }
    let workspaceTabs = new Map();
    let tabCounter = 0;

    // Current workspace's active tab references
    let activeTabId = null;

    // Right panel state
    let activeToolView = 'explorer';
    let explorerTree = new Map(); // path -> items (cached)
    let expandedDirs = new Set(); // expanded directory paths
    let allFilePaths = []; // for search (from explorer)
    let gitStatus = [];

    // File index cache for Quick Open (Cmd+P)
    // Map<workspaceKey, {items: string[], truncated: boolean, updatedAt: number}>
    let workspaceFileIndex = new Map();

    // DOM elements
    let tabBar = null;
    let tabContent = null;
    let placeholder = null;
    let projectTree = null;

    function getWorkspaceKey(project, workspace) {
        return `${project}/${workspace}`;
    }

    function getCurrentWorkspaceKey() {
        if (!currentProject || !currentWorkspace) return null;
        return getWorkspaceKey(currentProject, currentWorkspace);
    }

    function getOrCreateTabSet(wsKey) {
        if (!workspaceTabs.has(wsKey)) {
            workspaceTabs.set(wsKey, {
                tabs: new Map(),
                activeTabId: null,
                tabOrder: []
            });
        }
        return workspaceTabs.get(wsKey);
    }

    function initUI() {
        tabBar = document.getElementById('tab-bar');
        tabContent = document.getElementById('tab-content');
        placeholder = document.getElementById('placeholder');
        projectTree = document.getElementById('project-tree');

        // New terminal button
        const newTermBtn = document.getElementById('new-terminal-btn');
        if (newTermBtn) {
            newTermBtn.addEventListener('click', () => {
                if (currentProject && currentWorkspace) {
                    createTerminal(currentProject, currentWorkspace);
                }
            });
        }

        // Refresh projects button
        const refreshBtn = document.getElementById('refresh-projects');
        if (refreshBtn) {
            refreshBtn.addEventListener('click', listProjects);
        }

        // Tool icon switching
        document.querySelectorAll('.tool-icon').forEach(icon => {
            icon.addEventListener('click', () => {
                switchToolView(icon.dataset.tool);
            });
        });

        // Search input
        const searchInput = document.getElementById('search-input');
        if (searchInput) {
            searchInput.addEventListener('input', (e) => {
                performSearch(e.target.value);
            });
        }

        // Git refresh button
        const gitRefreshBtn = document.getElementById('git-refresh-btn');
        if (gitRefreshBtn) {
            gitRefreshBtn.addEventListener('click', refreshGitStatus);
        }

        // Keyboard shortcuts
        document.addEventListener('keydown', (e) => {
            if ((e.metaKey || e.ctrlKey) && e.key === 's') {
                e.preventDefault();
                saveCurrentEditor();
            }
        });
    }

    // ============================================
    // Tool Panel Functions
    // ============================================

    function switchToolView(toolName) {
        activeToolView = toolName;

        // Update icon states
        document.querySelectorAll('.tool-icon').forEach(icon => {
            icon.classList.toggle('active', icon.dataset.tool === toolName);
        });

        // Update view visibility
        document.querySelectorAll('.tool-view').forEach(view => {
            view.classList.toggle('active', view.id === `${toolName}-view`);
        });

        // Refresh view content
        if (toolName === 'explorer') refreshExplorer();
        if (toolName === 'git') refreshGitStatus();
    }

    function refreshExplorer() {
        const explorerTreeEl = document.getElementById('explorer-tree');
        if (!explorerTreeEl) return;

        if (!currentProject || !currentWorkspace) {
            explorerTreeEl.innerHTML = '<div class="file-empty">No workspace selected</div>';
            return;
        }

        // Request root directory listing
        sendFileList(currentProject, currentWorkspace, '.');
    }

    function renderExplorerTree(path, items) {
        const explorerTreeEl = document.getElementById('explorer-tree');
        if (!explorerTreeEl) return;

        // Cache items
        explorerTree.set(path, items);

        if (path === '.') {
            // Root level - rebuild entire tree
            explorerTreeEl.innerHTML = '';
            if (items.length === 0) {
                explorerTreeEl.innerHTML = '<div class="file-empty">Empty directory</div>';
                return;
            }
            items.forEach(item => {
                explorerTreeEl.appendChild(createFileItem(item, '.'));
            });
        } else {
            // Subdirectory - find and update the parent
            const parentEl = explorerTreeEl.querySelector(`[data-path="${path}"]`);
            if (parentEl) {
                let childrenEl = parentEl.querySelector('.file-children');
                if (!childrenEl) {
                    childrenEl = document.createElement('div');
                    childrenEl.className = 'file-children';
                    parentEl.appendChild(childrenEl);
                }
                childrenEl.innerHTML = '';
                items.forEach(item => {
                    childrenEl.appendChild(createFileItem(item, path));
                });
            }
        }

        // Update allFilePaths for search
        updateFilePathsCache();
    }

    function createFileItem(item, parentPath) {
        const fullPath = parentPath === '.' ? item.name : `${parentPath}/${item.name}`;
        const el = document.createElement('div');
        el.className = 'file-item' + (item.is_dir ? ' directory' : '');
        el.dataset.path = fullPath;

        const icon = document.createElement('span');
        icon.className = 'file-icon';
        icon.textContent = item.is_dir ? '▶' : getFileIcon(item.name);
        el.appendChild(icon);

        const name = document.createElement('span');
        name.className = 'file-name';
        name.textContent = item.name;
        el.appendChild(name);

        if (!item.is_dir) {
            const size = document.createElement('span');
            size.className = 'file-size';
            size.textContent = formatSize(item.size);
            el.appendChild(size);
        }

        el.addEventListener('click', (e) => {
            e.stopPropagation();
            if (item.is_dir) {
                toggleDirectory(el, fullPath);
            } else {
                openFileInEditor(fullPath);
            }
        });

        // If directory is expanded, add children container
        if (item.is_dir && expandedDirs.has(fullPath)) {
            el.classList.add('expanded');
            const childrenEl = document.createElement('div');
            childrenEl.className = 'file-children';
            el.appendChild(childrenEl);
            // Request children
            sendFileList(currentProject, currentWorkspace, fullPath);
        }

        return el;
    }

    function toggleDirectory(el, path) {
        if (expandedDirs.has(path)) {
            expandedDirs.delete(path);
            el.classList.remove('expanded');
            const childrenEl = el.querySelector('.file-children');
            if (childrenEl) childrenEl.remove();
        } else {
            expandedDirs.add(path);
            el.classList.add('expanded');
            const childrenEl = document.createElement('div');
            childrenEl.className = 'file-children';
            childrenEl.innerHTML = '<div class="file-empty">Loading...</div>';
            el.appendChild(childrenEl);
            sendFileList(currentProject, currentWorkspace, path);
        }
    }

    function getFileIcon(filename) {
        const ext = filename.split('.').pop().toLowerCase();
        const icons = {
            'js': '📜', 'ts': '📘', 'jsx': '⚛️', 'tsx': '⚛️',
            'html': '🌐', 'css': '🎨', 'json': '📋',
            'md': '📝', 'txt': '📄',
            'rs': '🦀', 'go': '🐹', 'py': '🐍',
            'swift': '🍎', 'java': '☕',
            'png': '🖼️', 'jpg': '🖼️', 'gif': '🖼️', 'svg': '🖼️',
        };
        return icons[ext] || '📄';
    }

    function formatSize(bytes) {
        if (bytes < 1024) return bytes + ' B';
        if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
        return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
    }

    function updateFilePathsCache() {
        allFilePaths = [];
        function collectPaths(path, items) {
            items.forEach(item => {
                const fullPath = path === '.' ? item.name : `${path}/${item.name}`;
                if (!item.is_dir) {
                    allFilePaths.push(fullPath);
                }
                if (item.is_dir && explorerTree.has(fullPath)) {
                    collectPaths(fullPath, explorerTree.get(fullPath));
                }
            });
        }
        if (explorerTree.has('.')) {
            collectPaths('.', explorerTree.get('.'));
        }
    }

    function performSearch(query) {
        const resultsEl = document.getElementById('search-results');
        if (!resultsEl) return;

        if (!query.trim()) {
            resultsEl.innerHTML = '<div class="search-empty">Enter a search term</div>';
            return;
        }

        const lowerQuery = query.toLowerCase();
        const matches = allFilePaths.filter(p => p.toLowerCase().includes(lowerQuery));

        if (matches.length === 0) {
            resultsEl.innerHTML = '<div class="search-empty">No files found</div>';
            return;
        }

        resultsEl.innerHTML = '';
        matches.slice(0, 50).forEach(path => {
            const el = document.createElement('div');
            el.className = 'search-result';

            const icon = document.createElement('span');
            icon.className = 'file-icon';
            icon.textContent = getFileIcon(path);
            el.appendChild(icon);

            const name = document.createElement('span');
            name.className = 'file-name';
            // Highlight match
            const idx = path.toLowerCase().indexOf(lowerQuery);
            name.innerHTML = path.substring(0, idx) +
                '<span class="match">' + path.substring(idx, idx + query.length) + '</span>' +
                path.substring(idx + query.length);
            el.appendChild(name);

            el.addEventListener('click', () => openFileInEditor(path));
            resultsEl.appendChild(el);
        });
    }

    function refreshGitStatus() {
        const listEl = document.getElementById('git-status-list');
        if (!listEl) return;

        if (!currentProject || !currentWorkspace) {
            listEl.innerHTML = '<div class="git-empty">No workspace selected</div>';
            return;
        }

        listEl.innerHTML = '<div class="git-empty">Loading...</div>';
        sendControlMessage({ type: 'git_status', project: currentProject, workspace: currentWorkspace });
    }

    function renderGitStatus(repoRoot, items) {
        const listEl = document.getElementById('git-status-list');
        const headerEl = document.getElementById('git-repo-header');
        if (!listEl) return;

        // Update header with repo root
        if (headerEl) {
            if (repoRoot) {
                headerEl.textContent = repoRoot.split('/').pop() || 'Repository';
                headerEl.title = repoRoot;
            } else {
                headerEl.textContent = 'Not a git repo';
                headerEl.title = '';
            }
        }

        if (!repoRoot) {
            listEl.innerHTML = '<div class="git-empty">Not a git repository</div>';
            return;
        }

        if (items.length === 0) {
            listEl.innerHTML = '<div class="git-empty">Working tree clean</div>';
            return;
        }

        listEl.innerHTML = '';
        items.forEach(item => {
            const el = document.createElement('div');
            el.className = 'git-item';

            const status = document.createElement('span');
            status.className = 'git-status';
            status.textContent = item.code;
            if (item.code === 'M') status.classList.add('modified');
            else if (item.code === 'A') status.classList.add('added');
            else if (item.code === 'D') status.classList.add('deleted');
            else if (item.code === '??' || item.code === '?') status.classList.add('untracked');
            else if (item.code === 'R' || item.code === 'C') status.classList.add('renamed');
            el.appendChild(status);

            const file = document.createElement('span');
            file.className = 'git-file';
            file.textContent = item.path;
            if (item.orig_path) {
                file.title = `Renamed from: ${item.orig_path}`;
            }
            el.appendChild(file);

            // Click opens Diff Tab instead of Editor
            el.addEventListener('click', () => openDiffTab(item.path, item.code));
            listEl.appendChild(el);
        });
    }

    // ============================================
    // Diff Tab Functions
    // ============================================

    function createDiffTab(filePath, code) {
        const wsKey = getCurrentWorkspaceKey();
        if (!wsKey) return null;

        const tabSet = getOrCreateTabSet(wsKey);
        const tabId = 'diff-' + filePath.replace(/[^a-zA-Z0-9]/g, '-');

        // Check if tab already exists
        if (tabSet.tabs.has(tabId)) {
            switchToTab(tabId);
            // Refresh diff content
            sendGitDiff(currentProject, currentWorkspace, filePath);
            return tabSet.tabs.get(tabId);
        }

        // Create pane
        const pane = document.createElement('div');
        pane.className = 'tab-pane diff-pane';
        pane.id = 'pane-' + tabId;

        // Diff toolbar
        const toolbar = document.createElement('div');
        toolbar.className = 'diff-toolbar';

        const pathEl = document.createElement('span');
        pathEl.className = 'diff-path';
        pathEl.textContent = filePath;
        toolbar.appendChild(pathEl);

        const codeEl = document.createElement('span');
        codeEl.className = 'diff-code';
        codeEl.textContent = `[${code}]`;
        toolbar.appendChild(codeEl);

        // Open file button
        const openFileBtn = document.createElement('button');
        openFileBtn.className = 'diff-open-btn';
        openFileBtn.textContent = '📄 Open file';
        openFileBtn.title = 'Open file in editor';
        // Disable for deleted files
        if (code === 'D') {
            openFileBtn.disabled = true;
            openFileBtn.title = 'File has been deleted';
        }
        openFileBtn.addEventListener('click', () => {
            const tab = tabSet.tabs.get(tabId);
            if (tab && tab.code !== 'D') {
                openFileInEditor(tab.filePath);
            }
        });
        toolbar.appendChild(openFileBtn);

        const refreshBtn = document.createElement('button');
        refreshBtn.className = 'diff-refresh-btn';
        refreshBtn.textContent = '↻ Refresh';
        refreshBtn.addEventListener('click', () => {
            const tab = tabSet.tabs.get(tabId);
            if (tab) {
                tab.contentEl.innerHTML = '<div class="diff-loading">Loading diff...</div>';
                sendGitDiff(tab.project, tab.workspace, tab.filePath);
            }
        });
        toolbar.appendChild(refreshBtn);

        pane.appendChild(toolbar);

        // Diff content container
        const contentEl = document.createElement('div');
        contentEl.className = 'diff-content';
        contentEl.innerHTML = '<div class="diff-loading">Loading diff...</div>';
        pane.appendChild(contentEl);

        // Status bar
        const statusBar = document.createElement('div');
        statusBar.className = 'diff-status';
        pane.appendChild(statusBar);

        tabContent.appendChild(pane);

        // Create tab element
        const tabEl = document.createElement('div');
        tabEl.className = 'tab';
        tabEl.dataset.tabId = tabId;

        const icon = document.createElement('span');
        icon.className = 'tab-icon diff';
        icon.textContent = '±';
        tabEl.appendChild(icon);

        const title = document.createElement('span');
        title.className = 'tab-title';
        title.textContent = filePath.split('/').pop() + ' (diff)';
        title.title = filePath;
        tabEl.appendChild(title);

        const closeBtn = document.createElement('span');
        closeBtn.className = 'tab-close';
        closeBtn.textContent = '×';
        closeBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            closeTab(tabId);
        });
        tabEl.appendChild(closeBtn);

        tabEl.addEventListener('click', () => switchToTab(tabId));

        const tabActions = document.getElementById('tab-actions');
        tabBar.insertBefore(tabEl, tabActions);

        // Store tab info
        const tabInfo = {
            id: tabId,
            type: 'diff',
            title: filePath.split('/').pop() + ' (diff)',
            filePath,
            code,
            pane,
            tabEl,
            contentEl,
            statusBar,
            project: currentProject,
            workspace: currentWorkspace
        };

        tabSet.tabs.set(tabId, tabInfo);
        tabSet.tabOrder.push(tabId);

        return tabInfo;
    }

    function openDiffTab(filePath, code) {
        if (!currentProject || !currentWorkspace) return;

        const tabInfo = createDiffTab(filePath, code);
        if (tabInfo) {
            switchToTab(tabInfo.id);
            sendGitDiff(currentProject, currentWorkspace, filePath);
        }
    }

    function renderDiffContent(path, code, text, isBinary, truncated) {
        const wsKey = getCurrentWorkspaceKey();
        if (!wsKey) return;

        const tabSet = workspaceTabs.get(wsKey);
        if (!tabSet) return;

        const tabId = 'diff-' + path.replace(/[^a-zA-Z0-9]/g, '-');
        const tab = tabSet.tabs.get(tabId);
        if (!tab || !tab.contentEl) return;

        // Update open button state based on code
        const openBtn = tab.pane.querySelector('.diff-open-btn');
        if (openBtn) {
            if (code === 'D') {
                openBtn.disabled = true;
                openBtn.title = 'File has been deleted';
            } else {
                openBtn.disabled = false;
                openBtn.title = 'Open file in editor';
            }
        }

        if (isBinary) {
            tab.contentEl.innerHTML = '<div class="diff-binary">Binary file diff not supported</div>';
            return;
        }

        if (!text || text.trim() === '') {
            tab.contentEl.innerHTML = '<div class="diff-empty">No changes</div>';
            return;
        }

        // Parse unified diff and render with line navigation
        const pre = document.createElement('pre');
        pre.className = 'diff-text';

        const lines = text.split('\n');
        let currentNewLine = 0;
        let currentOldLine = 0;
        let inHunk = false;

        lines.forEach((line, idx) => {
            const lineEl = document.createElement('div');
            lineEl.className = 'diff-line';

            // Parse hunk header: @@ -oldStart,oldCount +newStart,newCount @@
            const hunkMatch = line.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
            if (hunkMatch) {
                currentOldLine = parseInt(hunkMatch[1], 10);
                currentNewLine = parseInt(hunkMatch[2], 10);
                inHunk = true;
                lineEl.classList.add('diff-hunk');
                lineEl.textContent = line;
                pre.appendChild(lineEl);
                return;
            }

            // Header lines (not clickable)
            if (line.startsWith('diff --git') || line.startsWith('index ') ||
                line.startsWith('---') || line.startsWith('+++') ||
                line.startsWith('new file') || line.startsWith('deleted file') ||
                line.startsWith('Binary files')) {
                lineEl.classList.add('diff-header');
                lineEl.textContent = line;
                pre.appendChild(lineEl);
                return;
            }

            // Content lines within a hunk
            if (inHunk) {
                const firstChar = line.charAt(0);

                if (firstChar === '+') {
                    lineEl.classList.add('diff-add');
                    lineEl.dataset.lineNew = currentNewLine;
                    lineEl.dataset.path = path;
                    lineEl.dataset.clickable = 'true';
                    currentNewLine++;
                } else if (firstChar === '-') {
                    lineEl.classList.add('diff-remove');
                    // For deleted lines, jump to the nearest new line position
                    lineEl.dataset.lineNew = currentNewLine;
                    lineEl.dataset.path = path;
                    lineEl.dataset.clickable = 'true';
                    currentOldLine++;
                } else if (firstChar === ' ') {
                    // Context line
                    lineEl.dataset.lineNew = currentNewLine;
                    lineEl.dataset.path = path;
                    lineEl.dataset.clickable = 'true';
                    currentNewLine++;
                    currentOldLine++;
                } else if (line === '\\ No newline at end of file') {
                    // Special marker, not clickable
                    lineEl.classList.add('diff-meta');
                }
            }

            lineEl.textContent = line;
            pre.appendChild(lineEl);
        });

        // Add click handler for line navigation
        pre.addEventListener('click', (e) => {
            const lineEl = e.target.closest('.diff-line');
            if (!lineEl || lineEl.dataset.clickable !== 'true') return;

            const targetLine = parseInt(lineEl.dataset.lineNew, 10);
            const targetPath = lineEl.dataset.path;

            if (targetPath && !isNaN(targetLine) && code !== 'D') {
                openFileAtLine(targetPath, targetLine);
            }
        });

        tab.contentEl.innerHTML = '';
        tab.contentEl.appendChild(pre);

        // Update status bar
        if (tab.statusBar) {
            let status = 'Click any line to jump to that location in the file';
            if (truncated) {
                status = '⚠️ Diff too large, truncated to 1MB | ' + status;
            }
            if (code === 'D') {
                status = 'File deleted - navigation disabled';
            }
            tab.statusBar.textContent = status;
        }
    }

    function sendGitDiff(project, workspace, path) {
        sendControlMessage({ type: 'git_diff', project, workspace, path });
    }

    // ============================================
    // Project Tree Functions
    // ============================================

    function renderProjectTree() {
        if (!projectTree) return;
        projectTree.innerHTML = '';

        projects.forEach(proj => {
            // Project node
            const projEl = document.createElement('div');
            projEl.className = 'tree-item project';
            projEl.innerHTML = `<span class="tree-icon">📦</span><span class="tree-name">${proj.name}</span>`;
            projEl.addEventListener('click', () => {
                listWorkspaces(proj.name);
            });
            projectTree.appendChild(projEl);

            // Workspaces under this project
            const wsItems = workspacesMap.get(proj.name) || [];
            wsItems.forEach(ws => {
                const wsEl = document.createElement('div');
                wsEl.className = 'tree-item workspace';
                if (currentProject === proj.name && currentWorkspace === ws.name) {
                    wsEl.classList.add('selected');
                }
                wsEl.innerHTML = `<span class="tree-icon">📁</span><span class="tree-name">${ws.name}</span>`;
                wsEl.addEventListener('click', (e) => {
                    e.stopPropagation();
                    selectWorkspace(proj.name, ws.name);
                });
                projectTree.appendChild(wsEl);
            });
        });
    }

    // ============================================
    // Tab Management (Workspace-Scoped)
    // ============================================

    function createTerminalTab(termId, cwd, project, workspace) {
        tabCounter++;
        const wsKey = getWorkspaceKey(project, workspace);
        const tabSet = getOrCreateTabSet(wsKey);

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

        // Create pane container
        const pane = document.createElement('div');
        pane.className = 'tab-pane terminal-pane';
        pane.id = 'pane-' + termId;

        const container = document.createElement('div');
        container.className = 'terminal-container';
        pane.appendChild(container);
        tabContent.appendChild(pane);

        // Open terminal
        term.open(container);

        // Create tab element
        const tabEl = document.createElement('div');
        tabEl.className = 'tab';
        tabEl.dataset.tabId = termId;

        const icon = document.createElement('span');
        icon.className = 'tab-icon terminal';
        icon.textContent = '⌘';
        tabEl.appendChild(icon);

        const title = document.createElement('span');
        title.className = 'tab-title';
        title.textContent = workspace || 'Terminal';
        tabEl.appendChild(title);

        const closeBtn = document.createElement('span');
        closeBtn.className = 'tab-close';
        closeBtn.textContent = '×';
        closeBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            closeTab(termId);
        });
        tabEl.appendChild(closeBtn);

        tabEl.addEventListener('click', () => switchToTab(termId));

        // Insert before tab-actions
        const tabActions = document.getElementById('tab-actions');
        tabBar.insertBefore(tabEl, tabActions);

        // Handle input
        term.onData((data) => {
            if (transport && transport.isConnected) {
                const encoder = new TextEncoder();
                const bytes = encoder.encode(data);
                transport.send(JSON.stringify({
                    type: 'input',
                    term_id: termId,
                    data_b64: encodeBase64(bytes)
                }));
            }
        });

        // Handle resize
        const resizeObserver = new ResizeObserver(() => {
            if (fitAddon && activeTabId === termId) {
                fitAddon.fit();
                sendResize(termId, term.cols, term.rows);
            }
        });
        resizeObserver.observe(container);

        // Store tab info
        const tabInfo = {
            id: termId,
            type: 'terminal',
            title: workspace || 'Terminal',
            termId: termId,
            term,
            fitAddon,
            pane,
            tabEl,
            cwd: cwd || '',
            project,
            workspace,
            resizeObserver
        };

        tabSet.tabs.set(termId, tabInfo);
        tabSet.tabOrder.push(termId);

        return tabInfo;
    }

    function createEditorTab(filePath, content) {
        const wsKey = getCurrentWorkspaceKey();
        if (!wsKey) return null;

        const tabSet = getOrCreateTabSet(wsKey);
        const tabId = 'editor-' + filePath.replace(/[^a-zA-Z0-9]/g, '-');

        // Check if tab already exists
        if (tabSet.tabs.has(tabId)) {
            switchToTab(tabId);
            return tabSet.tabs.get(tabId);
        }

        // Create pane
        const pane = document.createElement('div');
        pane.className = 'tab-pane editor-pane';
        pane.id = 'pane-' + tabId;

        // Editor toolbar
        const toolbar = document.createElement('div');
        toolbar.className = 'editor-toolbar';

        const pathEl = document.createElement('span');
        pathEl.className = 'editor-path';
        pathEl.textContent = filePath;
        toolbar.appendChild(pathEl);

        const saveBtn = document.createElement('button');
        saveBtn.className = 'editor-save-btn';
        saveBtn.textContent = 'Save';
        saveBtn.disabled = true;
        saveBtn.addEventListener('click', () => saveEditorTab(tabId));
        toolbar.appendChild(saveBtn);

        pane.appendChild(toolbar);

        // Editor container
        const editorContainer = document.createElement('div');
        editorContainer.className = 'editor-container';
        pane.appendChild(editorContainer);

        // Status bar
        const statusBar = document.createElement('div');
        statusBar.className = 'editor-status';
        pane.appendChild(statusBar);

        tabContent.appendChild(pane);

        // Create CodeMirror editor
        let editorView = null;
        if (window.CodeMirror) {
            const { EditorView, basicSetup } = window.CodeMirror;
            editorView = new EditorView({
                doc: content || '',
                extensions: [
                    basicSetup,
                    EditorView.updateListener.of((update) => {
                        if (update.docChanged) {
                            const tab = tabSet.tabs.get(tabId);
                            if (tab && !tab.isDirty) {
                                tab.isDirty = true;
                                updateTabDirtyState(tabId, true);
                            }
                        }
                    }),
                    EditorView.theme({
                        '&': { height: '100%', fontSize: '14px' },
                        '.cm-scroller': { fontFamily: 'Menlo, Monaco, "Courier New", monospace' },
                        '.cm-content': { caretColor: '#d4d4d4' },
                        '&.cm-focused .cm-cursor': { borderLeftColor: '#d4d4d4' },
                    }, { dark: true }),
                ],
                parent: editorContainer,
            });
        }

        // Create tab element
        const tabEl = document.createElement('div');
        tabEl.className = 'tab';
        tabEl.dataset.tabId = tabId;

        const icon = document.createElement('span');
        icon.className = 'tab-icon editor';
        icon.textContent = getFileIcon(filePath);
        tabEl.appendChild(icon);

        const title = document.createElement('span');
        title.className = 'tab-title';
        title.textContent = filePath.split('/').pop();
        title.title = filePath;
        tabEl.appendChild(title);

        const dirtyIndicator = document.createElement('span');
        dirtyIndicator.className = 'tab-dirty';
        dirtyIndicator.style.display = 'none';
        dirtyIndicator.textContent = '*';
        tabEl.appendChild(dirtyIndicator);

        const closeBtn = document.createElement('span');
        closeBtn.className = 'tab-close';
        closeBtn.textContent = '×';
        closeBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            closeTab(tabId);
        });
        tabEl.appendChild(closeBtn);

        tabEl.addEventListener('click', () => switchToTab(tabId));

        const tabActions = document.getElementById('tab-actions');
        tabBar.insertBefore(tabEl, tabActions);

        // Store tab info
        const tabInfo = {
            id: tabId,
            type: 'editor',
            title: filePath.split('/').pop(),
            filePath,
            editorView,
            pane,
            tabEl,
            saveBtn,
            statusBar,
            dirtyIndicator,
            isDirty: false,
            project: currentProject,
            workspace: currentWorkspace
        };

        tabSet.tabs.set(tabId, tabInfo);
        tabSet.tabOrder.push(tabId);

        return tabInfo;
    }

    function updateTabDirtyState(tabId, isDirty) {
        const wsKey = getCurrentWorkspaceKey();
        if (!wsKey) return;

        const tabSet = workspaceTabs.get(wsKey);
        if (!tabSet) return;

        const tab = tabSet.tabs.get(tabId);
        if (!tab) return;

        tab.isDirty = isDirty;
        if (tab.dirtyIndicator) {
            tab.dirtyIndicator.style.display = isDirty ? 'inline' : 'none';
        }
        if (tab.saveBtn) {
            tab.saveBtn.disabled = !isDirty;
        }
    }

    function saveEditorTab(tabId) {
        const wsKey = getCurrentWorkspaceKey();
        if (!wsKey) return;

        const tabSet = workspaceTabs.get(wsKey);
        if (!tabSet) return;

        const tab = tabSet.tabs.get(tabId);
        if (!tab || tab.type !== 'editor' || !tab.editorView) return;

        const content = tab.editorView.state.doc.toString();
        const encoder = new TextEncoder();
        const bytes = encoder.encode(content);
        const content_b64 = encodeBase64(bytes);

        sendFileWrite(tab.project, tab.workspace, tab.filePath, content_b64);
    }

    function saveCurrentEditor() {
        if (!activeTabId) return;
        const wsKey = getCurrentWorkspaceKey();
        if (!wsKey) return;

        const tabSet = workspaceTabs.get(wsKey);
        if (!tabSet) return;

        const tab = tabSet.tabs.get(activeTabId);
        if (tab && tab.type === 'editor') {
            saveEditorTab(activeTabId);
        }
    }

    function openFileInEditor(filePath) {
        if (!currentProject || !currentWorkspace) return;
        sendFileRead(currentProject, currentWorkspace, filePath);
    }

    // Pending line navigation (set before file read, consumed after tab creation)
    let pendingLineNavigation = null;

    function openFileAtLine(filePath, lineNumber) {
        if (!currentProject || !currentWorkspace) return;

        const wsKey = getCurrentWorkspaceKey();
        const tabId = 'editor-' + filePath.replace(/[^a-zA-Z0-9]/g, '-');

        // Check if editor tab already exists
        if (wsKey && workspaceTabs.has(wsKey)) {
            const tabSet = workspaceTabs.get(wsKey);
            if (tabSet.tabs.has(tabId)) {
                const tab = tabSet.tabs.get(tabId);
                switchToTab(tabId);
                scrollToLineAndHighlight(tab, lineNumber);
                return;
            }
        }

        // Tab doesn't exist, set pending navigation and open file
        pendingLineNavigation = { filePath, lineNumber };
        sendFileRead(currentProject, currentWorkspace, filePath);
    }

    function scrollToLineAndHighlight(tab, lineNumber) {
        if (!tab || !tab.editorView || !window.CodeMirror) return;

        const { EditorView } = window.CodeMirror;
        const view = tab.editorView;
        const doc = view.state.doc;

        // Clamp line number to valid range
        const totalLines = doc.lines;
        const targetLine = Math.max(1, Math.min(lineNumber, totalLines));

        // Get line position
        const lineInfo = doc.line(targetLine);
        const lineStart = lineInfo.from;

        // Scroll to line and set cursor
        view.dispatch({
            selection: { anchor: lineStart },
            scrollIntoView: true
        });

        // Highlight the line temporarily
        highlightLine(view, targetLine);

        // Update status bar
        if (tab.statusBar) {
            tab.statusBar.textContent = `Line ${targetLine}`;
        }
    }

    function highlightLine(view, lineNumber) {
        if (!window.CodeMirror) return;

        const { EditorView, Decoration, StateEffect, StateField } = window.CodeMirror;

        // Create highlight decoration
        const doc = view.state.doc;
        const lineInfo = doc.line(lineNumber);

        // Use a simple approach: add a temporary class to the line
        const highlightMark = Decoration.line({ class: 'cm-highlight-line' });
        const decorations = Decoration.set([highlightMark.range(lineInfo.from)]);

        // Define effect and field if not already defined
        if (!view._highlightEffect) {
            view._highlightEffect = StateEffect.define();
            view._highlightField = StateField.define({
                create: () => Decoration.none,
                update: (value, tr) => {
                    for (const e of tr.effects) {
                        if (e.is(view._highlightEffect)) {
                            return e.value;
                        }
                    }
                    return value;
                },
                provide: f => EditorView.decorations.from(f)
            });

            // Add the field to the editor
            view.dispatch({
                effects: StateEffect.appendConfig.of(view._highlightField)
            });
        }

        // Apply highlight
        view.dispatch({
            effects: view._highlightEffect.of(decorations)
        });

        // Remove highlight after 2 seconds
        setTimeout(() => {
            view.dispatch({
                effects: view._highlightEffect.of(Decoration.none)
            });
        }, 2000);
    }

    function switchToTab(tabId) {
        const wsKey = getCurrentWorkspaceKey();
        if (!wsKey) return;

        const tabSet = workspaceTabs.get(wsKey);
        if (!tabSet || !tabSet.tabs.has(tabId)) return;

        // Deactivate current tab
        if (activeTabId && tabSet.tabs.has(activeTabId)) {
            const current = tabSet.tabs.get(activeTabId);
            current.pane.classList.remove('active');
            current.tabEl.classList.remove('active');
        }

        // Activate new tab
        const tab = tabSet.tabs.get(tabId);
        tab.pane.classList.add('active');
        tab.tabEl.classList.add('active');
        activeTabId = tabId;
        tabSet.activeTabId = tabId;

        // Hide placeholder
        if (placeholder) placeholder.style.display = 'none';

        // Focus
        setTimeout(() => {
            if (tab.type === 'terminal' && tab.term) {
                tab.fitAddon.fit();
                tab.term.focus();
                sendResize(tab.termId, tab.term.cols, tab.term.rows);
            } else if (tab.type === 'editor' && tab.editorView) {
                tab.editorView.focus();
            }
        }, 0);

        notifySwift('tab_switched', { tab_id: tabId, type: tab.type });
    }

    function closeTab(tabId) {
        const wsKey = getCurrentWorkspaceKey();
        if (!wsKey) return;

        const tabSet = workspaceTabs.get(wsKey);
        if (!tabSet || !tabSet.tabs.has(tabId)) return;

        const tab = tabSet.tabs.get(tabId);

        // Check for unsaved changes
        if (tab.type === 'editor' && tab.isDirty) {
            if (!confirm('Unsaved changes will be lost. Close anyway?')) {
                return;
            }
        }

        // For terminals, send close request to server
        if (tab.type === 'terminal') {
            if (transport && transport.isConnected) {
                transport.send(JSON.stringify({
                    type: 'term_close',
                    term_id: tab.termId
                }));
            }
        }

        // Clean up
        removeTabFromUI(tabId);
    }

    function removeTabFromUI(tabId) {
        const wsKey = getCurrentWorkspaceKey();
        if (!wsKey) return;

        const tabSet = workspaceTabs.get(wsKey);
        if (!tabSet || !tabSet.tabs.has(tabId)) return;

        const tab = tabSet.tabs.get(tabId);

        // Dispose resources
        if (tab.type === 'terminal') {
            if (tab.resizeObserver) tab.resizeObserver.disconnect();
            if (tab.term) tab.term.dispose();
        } else if (tab.type === 'editor') {
            if (tab.editorView) tab.editorView.destroy();
        }

        // Remove DOM elements
        if (tab.pane) tab.pane.remove();
        if (tab.tabEl) tab.tabEl.remove();

        // Remove from tabSet
        tabSet.tabs.delete(tabId);
        tabSet.tabOrder = tabSet.tabOrder.filter(id => id !== tabId);

        // Switch to another tab if this was active
        if (activeTabId === tabId) {
            activeTabId = null;
            tabSet.activeTabId = null;
            if (tabSet.tabOrder.length > 0) {
                switchToTab(tabSet.tabOrder[tabSet.tabOrder.length - 1]);
            } else {
                // Show placeholder
                if (placeholder) placeholder.style.display = 'flex';
            }
        }
    }

    // ============================================
    // Workspace Switching
    // ============================================

    function switchWorkspaceUI(project, workspace, root) {
        const oldWsKey = getCurrentWorkspaceKey();
        const newWsKey = getWorkspaceKey(project, workspace);

        // Save current workspace state (hide tabs)
        if (oldWsKey && workspaceTabs.has(oldWsKey)) {
            const oldTabSet = workspaceTabs.get(oldWsKey);
            oldTabSet.tabs.forEach(tab => {
                tab.pane.classList.remove('active');
                tab.tabEl.style.display = 'none';
            });
        }

        // Update current workspace
        currentProject = project;
        currentWorkspace = workspace;
        currentWorkspaceRoot = root;

        // Restore or create new workspace tabs
        const newTabSet = getOrCreateTabSet(newWsKey);
        newTabSet.tabs.forEach(tab => {
            tab.tabEl.style.display = '';
        });

        // Restore active tab or show placeholder
        if (newTabSet.activeTabId && newTabSet.tabs.has(newTabSet.activeTabId)) {
            activeTabId = newTabSet.activeTabId;
            switchToTab(activeTabId);
        } else if (newTabSet.tabOrder.length > 0) {
            switchToTab(newTabSet.tabOrder[0]);
        } else {
            activeTabId = null;
            if (placeholder) placeholder.style.display = 'flex';
        }

        // Update UI state
        updateUIForWorkspace();
    }

    function updateUIForWorkspace() {
        // Enable/disable buttons
        const newTermBtn = document.getElementById('new-terminal-btn');
        if (newTermBtn) {
            newTermBtn.disabled = !currentProject || !currentWorkspace;
        }

        const searchInput = document.getElementById('search-input');
        if (searchInput) {
            searchInput.disabled = !currentProject || !currentWorkspace;
        }

        const gitRefreshBtn = document.getElementById('git-refresh-btn');
        if (gitRefreshBtn) {
            gitRefreshBtn.disabled = !currentProject || !currentWorkspace;
        }

        // Update project tree selection
        renderProjectTree();

        // Clear and refresh explorer
        explorerTree.clear();
        expandedDirs.clear();
        allFilePaths = [];

        // Refresh active tool view
        if (activeToolView === 'explorer') refreshExplorer();
        else if (activeToolView === 'git') refreshGitStatus();
    }

    // ============================================
    // Control Plane
    // ============================================

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
        sendControlMessage({ type: 'select_workspace', project, workspace });
    }

    function createTerminal(project, workspace) {
        sendControlMessage({ type: 'term_create', project, workspace });
    }

    function listTerminals() {
        sendControlMessage({ type: 'term_list' });
    }

    // File Operations API
    function sendFileList(project, workspace, path) {
        sendControlMessage({ type: 'file_list', project, workspace, path: path || '.' });
    }

    function sendFileRead(project, workspace, path) {
        sendControlMessage({ type: 'file_read', project, workspace, path });
    }

    function sendFileWrite(project, workspace, path, content_b64) {
        sendControlMessage({ type: 'file_write', project, workspace, path, content_b64 });
    }

    function sendFileIndex(project, workspace) {
        sendControlMessage({ type: 'file_index', project, workspace });
    }

    function sendResize(termId, cols, rows) {
        if (transport && transport.isConnected) {
            transport.send(JSON.stringify({
                type: 'resize',
                term_id: termId,
                cols: cols,
                rows: rows
            }));
        }
    }

    // ============================================
    // Message Handling
    // ============================================

    function handleMessage(data) {
        try {
            const msg = JSON.parse(data);

            switch (msg.type) {
                case 'hello': {
                    protocolVersion = msg.version || 0;
                    capabilities = msg.capabilities || [];

                    // Request projects list
                    listProjects();

                    notifySwift('hello', {
                        session_id: msg.session_id,
                        version: protocolVersion,
                        capabilities
                    });
                    break;
                }

                case 'output': {
                    // Find the terminal tab and write output
                    const termId = msg.term_id;
                    if (termId) {
                        // Search all workspace tabs for this terminal
                        for (const [wsKey, tabSet] of workspaceTabs) {
                            if (tabSet.tabs.has(termId)) {
                                const tab = tabSet.tabs.get(termId);
                                if (tab.term) {
                                    const bytes = decodeBase64(msg.data_b64);
                                    tab.term.write(bytes);
                                }
                                break;
                            }
                        }
                    }
                    break;
                }

                case 'exit': {
                    const termId = msg.term_id;
                    if (termId) {
                        for (const [wsKey, tabSet] of workspaceTabs) {
                            if (tabSet.tabs.has(termId)) {
                                const tab = tabSet.tabs.get(termId);
                                if (tab.term) {
                                    tab.term.writeln('');
                                    tab.term.writeln('\x1b[33m[Shell exited with code ' + msg.code + ']\x1b[0m');
                                }
                                break;
                            }
                        }
                    }
                    break;
                }

                case 'pong':
                    break;

                case 'projects':
                    projects = msg.items || [];
                    renderProjectTree();
                    notifySwift('projects', { items: projects });
                    break;

                case 'workspaces':
                    workspacesMap.set(msg.project, msg.items || []);
                    renderProjectTree();
                    notifySwift('workspaces', { project: msg.project, items: msg.items });
                    break;

                case 'selected_workspace': {
                    // Switch workspace UI
                    switchWorkspaceUI(msg.project, msg.workspace, msg.root);

                    // Create initial terminal for this workspace
                    const tabInfo = createTerminalTab(msg.session_id, msg.root, msg.project, msg.workspace);
                    switchToTab(msg.session_id);

                    if (tabInfo.term) {
                        tabInfo.term.writeln('\x1b[32m[Workspace: ' + msg.project + '/' + msg.workspace + ']\x1b[0m');
                        tabInfo.term.writeln('\x1b[90mRoot: ' + msg.root + '\x1b[0m');
                        tabInfo.term.writeln('\x1b[90mShell: ' + msg.shell + '\x1b[0m');
                        tabInfo.term.writeln('');

                        tabInfo.fitAddon.fit();
                        sendResize(msg.session_id, tabInfo.term.cols, tabInfo.term.rows);
                    }

                    notifySwift('workspace_selected', {
                        project: msg.project,
                        workspace: msg.workspace,
                        root: msg.root,
                        session_id: msg.session_id
                    });
                    break;
                }

                case 'term_created': {
                    const tabInfo = createTerminalTab(msg.term_id, msg.cwd, msg.project, msg.workspace);
                    switchToTab(msg.term_id);

                    if (tabInfo.term) {
                        tabInfo.term.writeln('\x1b[32m[New Terminal: ' + (msg.workspace || 'default') + ']\x1b[0m');
                        tabInfo.term.writeln('\x1b[90mCWD: ' + msg.cwd + '\x1b[0m');
                        tabInfo.term.writeln('\x1b[90mShell: ' + msg.shell + '\x1b[0m');
                        tabInfo.term.writeln('');

                        tabInfo.fitAddon.fit();
                        sendResize(msg.term_id, tabInfo.term.cols, tabInfo.term.rows);
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
                    // Find and remove the terminal tab
                    for (const [wsKey, tabSet] of workspaceTabs) {
                        if (tabSet.tabs.has(msg.term_id)) {
                            // Temporarily set current workspace to remove tab
                            const [proj, ws] = wsKey.split('/');
                            const savedProj = currentProject;
                            const savedWs = currentWorkspace;
                            currentProject = proj;
                            currentWorkspace = ws;
                            removeTabFromUI(msg.term_id);
                            currentProject = savedProj;
                            currentWorkspace = savedWs;
                            break;
                        }
                    }
                    notifySwift('term_closed', { term_id: msg.term_id });
                    break;

                // File operation responses
                case 'file_list_result':
                    if (msg.project === currentProject && msg.workspace === currentWorkspace) {
                        renderExplorerTree(msg.path, msg.items);
                    }
                    notifySwift('file_list', { project: msg.project, workspace: msg.workspace, items: msg.items });
                    break;

                case 'file_read_result':
                    if (msg.project === currentProject && msg.workspace === currentWorkspace) {
                        try {
                            const content = new TextDecoder().decode(decodeBase64(msg.content_b64));
                            const tabInfo = createEditorTab(msg.path, content);
                            if (tabInfo) {
                                switchToTab(tabInfo.id);

                                // Handle pending line navigation
                                if (pendingLineNavigation && pendingLineNavigation.filePath === msg.path) {
                                    const lineNumber = pendingLineNavigation.lineNumber;
                                    pendingLineNavigation = null;
                                    // Delay to ensure editor is fully initialized
                                    setTimeout(() => {
                                        scrollToLineAndHighlight(tabInfo, lineNumber);
                                    }, 50);
                                }
                            }
                        } catch (e) {
                            console.error('Failed to decode file content:', e);
                        }
                    }
                    notifySwift('file_read', { project: msg.project, workspace: msg.workspace, path: msg.path, size: msg.size });
                    break;

                case 'file_write_result':
                    if (msg.project === currentProject && msg.workspace === currentWorkspace && msg.success) {
                        // Find the editor tab and mark as clean
                        const wsKey = getCurrentWorkspaceKey();
                        if (wsKey && workspaceTabs.has(wsKey)) {
                            const tabSet = workspaceTabs.get(wsKey);
                            const tabId = 'editor-' + msg.path.replace(/[^a-zA-Z0-9]/g, '-');
                            if (tabSet.tabs.has(tabId)) {
                                updateTabDirtyState(tabId, false);
                                const tab = tabSet.tabs.get(tabId);
                                if (tab.statusBar) {
                                    tab.statusBar.textContent = 'Saved: ' + msg.path;
                                    setTimeout(() => { tab.statusBar.textContent = ''; }, 3000);
                                }
                            }
                        }
                    }
                    notifySwift('file_write', { project: msg.project, workspace: msg.workspace, path: msg.path, success: msg.success });
                    break;

                case 'file_index_result': {
                    const wsKey = getWorkspaceKey(msg.project, msg.workspace);
                    workspaceFileIndex.set(wsKey, {
                        items: msg.items || [],
                        truncated: msg.truncated || false,
                        updatedAt: Date.now()
                    });
                    // Notify palette that index is ready
                    if (window.tidyflowPalette && window.tidyflowPalette.onFileIndexReady) {
                        window.tidyflowPalette.onFileIndexReady(wsKey);
                    }
                    notifySwift('file_index', { project: msg.project, workspace: msg.workspace, count: msg.items?.length || 0, truncated: msg.truncated });
                    break;
                }

                case 'git_status_result':
                    if (msg.project === currentProject && msg.workspace === currentWorkspace) {
                        renderGitStatus(msg.repo_root, msg.items || []);
                    }
                    notifySwift('git_status', { project: msg.project, workspace: msg.workspace, count: msg.items?.length || 0 });
                    break;

                case 'git_diff_result':
                    if (msg.project === currentProject && msg.workspace === currentWorkspace) {
                        renderDiffContent(msg.path, msg.code, msg.text, msg.is_binary, msg.truncated);
                    }
                    notifySwift('git_diff', { project: msg.project, workspace: msg.workspace, path: msg.path });
                    break;

                case 'error':
                    console.error('Server error:', msg.code, msg.message);
                    notifySwift('error', { code: msg.code, message: msg.message });
                    break;

                default:
                    console.warn('Unknown message type:', msg.type);
            }
        } catch (e) {
            console.error('Failed to parse message:', e);
        }
    }

    // ============================================
    // Connection
    // ============================================

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
            },
            onError: (e) => {
                notifySwift('error', { message: e.message || 'Connection failed' });
            },
            onMessage: handleMessage
        });

        transport.connect();
    }

    function reconnect() {
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
        getActiveTabId: () => activeTabId,
        getProtocolVersion: () => protocolVersion,
        getCapabilities: () => capabilities,

        // Control Plane API
        listProjects,
        listWorkspaces,
        selectWorkspace,

        // Terminal API
        createTerminal,
        listTerminals,
        closeTab,
        switchToTab,

        // File Operations API
        sendFileList,
        sendFileRead,
        sendFileWrite,
        sendFileIndex,

        // File index cache for Quick Open
        getFileIndex: (project, workspace) => {
            const wsKey = getWorkspaceKey(project, workspace);
            return workspaceFileIndex.get(wsKey) || null;
        },
        refreshFileIndex: (project, workspace) => {
            const wsKey = getWorkspaceKey(project, workspace);
            workspaceFileIndex.delete(wsKey);
            sendFileIndex(project, workspace);
        },

        // State getters
        getProjects: () => projects,
        getWorkspacesMap: () => workspacesMap,
        getCurrentProject: () => currentProject,
        getCurrentWorkspace: () => currentWorkspace,
        getCurrentWorkspaceRoot: () => currentWorkspaceRoot,

        // Tab info
        getWorkspaceTabs: () => {
            const wsKey = getCurrentWorkspaceKey();
            if (!wsKey || !workspaceTabs.has(wsKey)) return [];
            const tabSet = workspaceTabs.get(wsKey);
            return tabSet.tabOrder.map(id => {
                const tab = tabSet.tabs.get(id);
                return {
                    id: tab.id,
                    type: tab.type,
                    title: tab.title,
                    filePath: tab.filePath,
                    isDirty: tab.isDirty
                };
            });
        },

        // Tool panel
        switchToolView,
        refreshExplorer,
        refreshGitStatus,

        // File index for palette
        getAllFilePaths: () => allFilePaths,
    };
})();
