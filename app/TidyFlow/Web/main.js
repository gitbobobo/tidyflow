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

    // Native mode state (Phase C1-2: Multi-Session)
    // 'editor' | 'terminal' - controls which UI is visible
    let nativeMode = 'editor';
    let nativeTerminalReady = false;

    // Phase C1-2: Multi-session management
    // Maps sessionId -> { buffer: string[], tabId: string, project: string, workspace: string }
    let terminalSessions = new Map();
    let activeSessionId = null;
    let pendingTerminalSpawn = null; // { tabId, project, workspace }
    const MAX_BUFFER_LINES = 2000;

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
            const existingTab = tabSet.tabs.get(tabId);
            sendGitDiff(currentProject, currentWorkspace, filePath, existingTab.diffMode || 'working');
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
                sendGitDiff(tab.project, tab.workspace, tab.filePath, tab.diffMode || 'working');
            }
        });
        toolbar.appendChild(refreshBtn);

        // Diff mode toggle (Working / Staged)
        const modeToggle = document.createElement('div');
        modeToggle.className = 'diff-mode-toggle';

        const workingBtn = document.createElement('button');
        workingBtn.className = 'diff-mode-btn active';
        workingBtn.textContent = 'Working';
        workingBtn.dataset.mode = 'working';
        workingBtn.title = 'Show unstaged changes (git diff)';

        const stagedBtn = document.createElement('button');
        stagedBtn.className = 'diff-mode-btn';
        stagedBtn.textContent = 'Staged';
        stagedBtn.dataset.mode = 'staged';
        stagedBtn.title = 'Show staged changes (git diff --cached)';

        modeToggle.appendChild(workingBtn);
        modeToggle.appendChild(stagedBtn);

        modeToggle.addEventListener('click', (e) => {
            const btn = e.target.closest('.diff-mode-btn');
            if (!btn) return;
            const newMode = btn.dataset.mode;
            const tab = tabSet.tabs.get(tabId);
            if (tab && tab.diffMode !== newMode) {
                modeToggle.querySelectorAll('.diff-mode-btn').forEach(b => b.classList.remove('active'));
                btn.classList.add('active');
                tab.diffMode = newMode;
                tab.contentEl.innerHTML = '<div class="diff-loading">Loading diff...</div>';
                sendGitDiff(tab.project, tab.workspace, tab.filePath, newMode);
            }
        });
        toolbar.appendChild(modeToggle);

        // View mode toggle (Unified / Split)
        const viewToggle = document.createElement('div');
        viewToggle.className = 'diff-view-toggle';

        const unifiedBtn = document.createElement('button');
        unifiedBtn.className = 'diff-view-btn active';
        unifiedBtn.textContent = 'Unified';
        unifiedBtn.dataset.mode = 'unified';

        const splitBtn = document.createElement('button');
        splitBtn.className = 'diff-view-btn';
        splitBtn.textContent = 'Split';
        splitBtn.dataset.mode = 'split';

        viewToggle.appendChild(unifiedBtn);
        viewToggle.appendChild(splitBtn);

        viewToggle.addEventListener('click', (e) => {
            const btn = e.target.closest('.diff-view-btn');
            if (!btn) return;
            const mode = btn.dataset.mode;
            const tab = tabSet.tabs.get(tabId);
            if (tab && tab.diffData && tab.viewMode !== mode) {
                viewToggle.querySelectorAll('.diff-view-btn').forEach(b => b.classList.remove('active'));
                btn.classList.add('active');
                tab.viewMode = mode;
                renderDiffView(tab);
            }
        });
        toolbar.appendChild(viewToggle);

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
            workspace: currentWorkspace,
            viewMode: 'unified',  // 'unified' or 'split'
            diffMode: 'working',  // 'working' or 'staged'
            diffData: null,       // Parsed diff data for reuse
            rawText: null,        // Raw diff text
            isBinary: false,
            truncated: false
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
            sendGitDiff(currentProject, currentWorkspace, filePath, tabInfo.diffMode);
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

        // Store raw data
        tab.rawText = text;
        tab.isBinary = isBinary;
        tab.truncated = truncated;
        tab.code = code;

        if (isBinary) {
            tab.contentEl.innerHTML = '<div class="diff-binary">Binary file diff not supported</div>';
            disableSplitMode(tab);
            return;
        }

        if (!text || text.trim() === '') {
            tab.contentEl.innerHTML = '<div class="diff-empty">No changes</div>';
            disableSplitMode(tab);
            return;
        }

        // Parse unified diff into structured format
        tab.diffData = parseDiffToStructure(text, path);

        // Check for large diff - disable split mode if > 5000 lines
        const totalLines = tab.diffData.hunks.reduce((sum, h) => sum + h.lines.length, 0);
        if (totalLines > 5000) {
            tab.viewMode = 'unified';
            disableSplitMode(tab, 'Diff too large for split view (' + totalLines + ' lines)');
        } else {
            enableSplitMode(tab);
        }

        // Render based on current view mode
        renderDiffView(tab);
    }

    function parseDiffToStructure(text, path) {
        const lines = text.split('\n');
        const result = {
            headers: [],
            hunks: [],
            path: path
        };

        let currentHunk = null;
        let currentOldLine = 0;
        let currentNewLine = 0;

        lines.forEach((line) => {
            // Parse hunk header
            const hunkMatch = line.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$/);
            if (hunkMatch) {
                if (currentHunk) {
                    result.hunks.push(currentHunk);
                }
                currentOldLine = parseInt(hunkMatch[1], 10);
                currentNewLine = parseInt(hunkMatch[2], 10);
                currentHunk = {
                    oldStart: currentOldLine,
                    newStart: currentNewLine,
                    header: line,
                    context: hunkMatch[3] || '',
                    lines: []
                };
                return;
            }

            // Header lines
            if (line.startsWith('diff --git') || line.startsWith('index ') ||
                line.startsWith('---') || line.startsWith('+++') ||
                line.startsWith('new file') || line.startsWith('deleted file') ||
                line.startsWith('Binary files')) {
                result.headers.push(line);
                return;
            }

            // Content lines within a hunk
            if (currentHunk) {
                const firstChar = line.charAt(0);

                if (firstChar === '+') {
                    currentHunk.lines.push({
                        type: 'add',
                        oldLine: null,
                        newLine: currentNewLine,
                        text: line
                    });
                    currentNewLine++;
                } else if (firstChar === '-') {
                    currentHunk.lines.push({
                        type: 'del',
                        oldLine: currentOldLine,
                        newLine: null,
                        text: line
                    });
                    currentOldLine++;
                } else if (firstChar === ' ') {
                    currentHunk.lines.push({
                        type: 'context',
                        oldLine: currentOldLine,
                        newLine: currentNewLine,
                        text: line
                    });
                    currentOldLine++;
                    currentNewLine++;
                } else if (line === '\\ No newline at end of file') {
                    currentHunk.lines.push({
                        type: 'meta',
                        oldLine: null,
                        newLine: null,
                        text: line
                    });
                } else if (line !== '') {
                    // Unknown line in hunk, treat as context
                    currentHunk.lines.push({
                        type: 'context',
                        oldLine: currentOldLine,
                        newLine: currentNewLine,
                        text: line
                    });
                }
            }
        });

        if (currentHunk) {
            result.hunks.push(currentHunk);
        }

        return result;
    }

    function disableSplitMode(tab, reason) {
        const splitBtn = tab.pane.querySelector('.diff-view-btn[data-mode="split"]');
        if (splitBtn) {
            splitBtn.disabled = true;
            splitBtn.title = reason || 'Split view not available';
        }
        // Force unified mode
        const unifiedBtn = tab.pane.querySelector('.diff-view-btn[data-mode="unified"]');
        if (unifiedBtn) {
            unifiedBtn.classList.add('active');
        }
        if (splitBtn) {
            splitBtn.classList.remove('active');
        }
        tab.viewMode = 'unified';
    }

    function enableSplitMode(tab) {
        const splitBtn = tab.pane.querySelector('.diff-view-btn[data-mode="split"]');
        if (splitBtn) {
            splitBtn.disabled = false;
            splitBtn.title = 'Split view (side-by-side)';
        }
    }

    function renderDiffView(tab) {
        if (!tab.diffData) return;

        // Save scroll position
        const scrollTop = tab.contentEl.scrollTop;

        if (tab.viewMode === 'split') {
            renderSplitDiff(tab);
        } else {
            renderUnifiedDiff(tab);
        }

        // Restore scroll position (approximate)
        tab.contentEl.scrollTop = scrollTop;

        // Update status bar
        updateDiffStatusBar(tab);
    }

    function renderUnifiedDiff(tab) {
        const data = tab.diffData;
        const pre = document.createElement('pre');
        pre.className = 'diff-text';

        // Render headers
        data.headers.forEach(line => {
            const lineEl = document.createElement('div');
            lineEl.className = 'diff-line diff-header';
            lineEl.textContent = line;
            pre.appendChild(lineEl);
        });

        // Render hunks
        data.hunks.forEach(hunk => {
            // Hunk header
            const hunkEl = document.createElement('div');
            hunkEl.className = 'diff-line diff-hunk';
            hunkEl.textContent = hunk.header;
            pre.appendChild(hunkEl);

            // Hunk lines
            hunk.lines.forEach(lineInfo => {
                const lineEl = document.createElement('div');
                lineEl.className = 'diff-line';

                if (lineInfo.type === 'add') {
                    lineEl.classList.add('diff-add');
                    lineEl.dataset.lineNew = lineInfo.newLine;
                    lineEl.dataset.path = data.path;
                    lineEl.dataset.clickable = 'true';
                } else if (lineInfo.type === 'del') {
                    lineEl.classList.add('diff-remove');
                    // For deleted lines, find nearest new line for navigation
                    const nearestNew = findNearestNewLine(hunk, lineInfo);
                    lineEl.dataset.lineNew = nearestNew;
                    lineEl.dataset.path = data.path;
                    lineEl.dataset.clickable = 'true';
                } else if (lineInfo.type === 'context') {
                    lineEl.dataset.lineNew = lineInfo.newLine;
                    lineEl.dataset.path = data.path;
                    lineEl.dataset.clickable = 'true';
                } else if (lineInfo.type === 'meta') {
                    lineEl.classList.add('diff-meta');
                }

                lineEl.textContent = lineInfo.text;
                pre.appendChild(lineEl);
            });
        });

        // Add click handler
        pre.addEventListener('click', (e) => {
            const lineEl = e.target.closest('.diff-line');
            if (!lineEl || lineEl.dataset.clickable !== 'true') return;

            const targetLine = parseInt(lineEl.dataset.lineNew, 10);
            const targetPath = lineEl.dataset.path;

            if (targetPath && !isNaN(targetLine) && tab.code !== 'D') {
                openFileAtLine(targetPath, targetLine);
            }
        });

        tab.contentEl.innerHTML = '';
        tab.contentEl.appendChild(pre);
    }

    function renderSplitDiff(tab) {
        const data = tab.diffData;

        const container = document.createElement('div');
        container.className = 'diff-split-container';

        // Render headers (full width)
        if (data.headers.length > 0) {
            const headersEl = document.createElement('div');
            headersEl.className = 'diff-split-headers';
            data.headers.forEach(line => {
                const lineEl = document.createElement('div');
                lineEl.className = 'diff-line diff-header';
                lineEl.textContent = line;
                headersEl.appendChild(lineEl);
            });
            container.appendChild(headersEl);
        }

        // Render hunks in split view
        data.hunks.forEach(hunk => {
            // Hunk header (full width)
            const hunkHeaderEl = document.createElement('div');
            hunkHeaderEl.className = 'diff-split-hunk-header diff-hunk';
            hunkHeaderEl.textContent = hunk.header;
            container.appendChild(hunkHeaderEl);

            // Split view for hunk content
            const splitEl = document.createElement('div');
            splitEl.className = 'diff-split';

            const oldPane = document.createElement('div');
            oldPane.className = 'diff-split-pane diff-old';

            const newPane = document.createElement('div');
            newPane.className = 'diff-split-pane diff-new';

            // Build aligned rows
            const rows = buildSplitRows(hunk.lines);

            rows.forEach(row => {
                // Old side (left)
                const oldRow = document.createElement('div');
                oldRow.className = 'diff-split-row';

                if (row.old) {
                    const lineNumEl = document.createElement('span');
                    lineNumEl.className = 'diff-line-num';
                    lineNumEl.textContent = row.old.oldLine || '';
                    oldRow.appendChild(lineNumEl);

                    const textEl = document.createElement('span');
                    textEl.className = 'diff-line-text';
                    if (row.old.type === 'del') {
                        textEl.classList.add('diff-remove');
                    } else if (row.old.type === 'context') {
                        textEl.classList.add('diff-context');
                    }
                    textEl.textContent = row.old.text.substring(1); // Remove +/- prefix
                    oldRow.appendChild(textEl);

                    // Click handler data
                    oldRow.dataset.clickable = 'true';
                    oldRow.dataset.path = data.path;
                    // For old side, jump to nearest new line
                    oldRow.dataset.lineNew = row.new ? row.new.newLine : (row.old.newLine || hunk.newStart);
                } else {
                    // Empty placeholder
                    oldRow.classList.add('diff-split-empty');
                    const lineNumEl = document.createElement('span');
                    lineNumEl.className = 'diff-line-num';
                    oldRow.appendChild(lineNumEl);
                    const textEl = document.createElement('span');
                    textEl.className = 'diff-line-text';
                    oldRow.appendChild(textEl);
                }
                oldPane.appendChild(oldRow);

                // New side (right)
                const newRow = document.createElement('div');
                newRow.className = 'diff-split-row';

                if (row.new) {
                    const lineNumEl = document.createElement('span');
                    lineNumEl.className = 'diff-line-num';
                    lineNumEl.textContent = row.new.newLine || '';
                    newRow.appendChild(lineNumEl);

                    const textEl = document.createElement('span');
                    textEl.className = 'diff-line-text';
                    if (row.new.type === 'add') {
                        textEl.classList.add('diff-add');
                    } else if (row.new.type === 'context') {
                        textEl.classList.add('diff-context');
                    }
                    textEl.textContent = row.new.text.substring(1); // Remove +/- prefix
                    newRow.appendChild(textEl);

                    // Click handler data
                    newRow.dataset.clickable = 'true';
                    newRow.dataset.path = data.path;
                    newRow.dataset.lineNew = row.new.newLine;
                } else {
                    // Empty placeholder
                    newRow.classList.add('diff-split-empty');
                    const lineNumEl = document.createElement('span');
                    lineNumEl.className = 'diff-line-num';
                    newRow.appendChild(lineNumEl);
                    const textEl = document.createElement('span');
                    textEl.className = 'diff-line-text';
                    newRow.appendChild(textEl);
                }
                newPane.appendChild(newRow);
            });

            splitEl.appendChild(oldPane);
            splitEl.appendChild(newPane);
            container.appendChild(splitEl);
        });

        // Add click handler for split view
        container.addEventListener('click', (e) => {
            const row = e.target.closest('.diff-split-row');
            if (!row || row.dataset.clickable !== 'true') return;

            const targetLine = parseInt(row.dataset.lineNew, 10);
            const targetPath = row.dataset.path;

            if (targetPath && !isNaN(targetLine) && tab.code !== 'D') {
                openFileAtLine(targetPath, targetLine);
            }
        });

        tab.contentEl.innerHTML = '';
        tab.contentEl.appendChild(container);
    }

    function buildSplitRows(lines) {
        const rows = [];
        let i = 0;

        while (i < lines.length) {
            const line = lines[i];

            if (line.type === 'context') {
                rows.push({ old: line, new: line });
                i++;
            } else if (line.type === 'del') {
                // Look ahead for consecutive adds to pair with
                let delLines = [];
                let addLines = [];

                // Collect consecutive del lines
                while (i < lines.length && lines[i].type === 'del') {
                    delLines.push(lines[i]);
                    i++;
                }

                // Collect consecutive add lines
                while (i < lines.length && lines[i].type === 'add') {
                    addLines.push(lines[i]);
                    i++;
                }

                // Pair them up
                const maxLen = Math.max(delLines.length, addLines.length);
                for (let j = 0; j < maxLen; j++) {
                    rows.push({
                        old: delLines[j] || null,
                        new: addLines[j] || null
                    });
                }
            } else if (line.type === 'add') {
                // Standalone add (no preceding del)
                rows.push({ old: null, new: line });
                i++;
            } else if (line.type === 'meta') {
                // Meta lines shown on both sides
                rows.push({ old: line, new: line });
                i++;
            } else {
                i++;
            }
        }

        return rows;
    }

    function findNearestNewLine(hunk, targetLine) {
        // Find the nearest new line number for a deleted line
        const idx = hunk.lines.indexOf(targetLine);
        if (idx === -1) return hunk.newStart;

        // Look forward for context or add line
        for (let i = idx + 1; i < hunk.lines.length; i++) {
            if (hunk.lines[i].newLine !== null) {
                return hunk.lines[i].newLine;
            }
        }

        // Look backward
        for (let i = idx - 1; i >= 0; i--) {
            if (hunk.lines[i].newLine !== null) {
                return hunk.lines[i].newLine;
            }
        }

        return hunk.newStart;
    }

    function updateDiffStatusBar(tab) {
        if (!tab.statusBar) return;

        let status = 'Click any line to jump to that location in the file';

        if (tab.viewMode === 'split') {
            status = 'Split view: Click left (old) or right (new) to jump | ' + status;
        }

        if (tab.truncated) {
            status = '⚠️ Diff too large, truncated to 1MB | ' + status;
        }

        if (tab.code === 'D') {
            status = 'File deleted - navigation disabled';
        }

        tab.statusBar.textContent = status;
    }

    function sendGitDiff(project, workspace, path, mode = 'working') {
        sendControlMessage({ type: 'git_diff', project, workspace, path, mode });
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

        // Phase C2-1: If in native diff mode, delegate to Native to open editor tab
        if (nativeMode === 'diff') {
            openFileAtLineViaNative(filePath, lineNumber);
            return;
        }

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

    function scrollToLineAndHighlight(tab, lineNumber, highlightMs = 2000) {
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
        highlightLine(view, targetLine, highlightMs);

        // Update status bar
        if (tab.statusBar) {
            tab.statusBar.textContent = `Line ${targetLine}`;
        }
    }

    function highlightLine(view, lineNumber, highlightMs = 2000) {
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

        // Remove highlight after specified duration
        setTimeout(() => {
            view.dispatch({
                effects: view._highlightEffect.of(Decoration.none)
            });
        }, highlightMs);
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
                    // Phase C1-2: Route output to correct session buffer
                    const termId = msg.term_id;
                    if (termId) {
                        const bytes = decodeBase64(msg.data_b64);

                        // Store in session buffer
                        if (terminalSessions.has(termId)) {
                            const session = terminalSessions.get(termId);
                            // Convert bytes to string for buffer
                            const text = new TextDecoder().decode(bytes);
                            session.buffer.push(text);
                            // Limit buffer size
                            while (session.buffer.length > MAX_BUFFER_LINES) {
                                session.buffer.shift();
                            }
                        }

                        // Write to xterm if this is the active session
                        if (termId === activeSessionId) {
                            // Search all workspace tabs for this terminal
                            for (const [wsKey, tabSet] of workspaceTabs) {
                                if (tabSet.tabs.has(termId)) {
                                    const tab = tabSet.tabs.get(termId);
                                    if (tab.term) {
                                        tab.term.write(bytes);
                                    }
                                    break;
                                }
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

                    // Phase C1-2: Register session (for legacy workspace selection)
                    terminalSessions.set(msg.session_id, {
                        buffer: [],
                        tabId: msg.session_id, // Legacy: tabId same as sessionId
                        project: msg.project,
                        workspace: msg.workspace
                    });
                    activeSessionId = msg.session_id;
                    nativeTerminalReady = true;

                    // Notify Native (legacy format for backward compatibility)
                    postToNative('terminal_ready', {
                        tab_id: msg.session_id,
                        session_id: msg.session_id,
                        project: msg.project,
                        workspace: msg.workspace
                    });

                    notifySwift('workspace_selected', {
                        project: msg.project,
                        workspace: msg.workspace,
                        root: msg.root,
                        session_id: msg.session_id
                    });
                    break;
                }

                case 'term_created': {
                    // Phase C1-2: Check if this was spawned by Native (has pending tabId)
                    const sessionId = msg.term_id;
                    const pendingTabId = pendingTerminalSpawn ? pendingTerminalSpawn.tabId : null;

                    const tabInfo = createTerminalTab(sessionId, msg.cwd, msg.project, msg.workspace);
                    switchToTab(sessionId);

                    if (tabInfo.term) {
                        tabInfo.term.writeln('\x1b[32m[New Terminal: ' + (msg.workspace || 'default') + ']\x1b[0m');
                        tabInfo.term.writeln('\x1b[90mCWD: ' + msg.cwd + '\x1b[0m');
                        tabInfo.term.writeln('\x1b[90mShell: ' + msg.shell + '\x1b[0m');
                        tabInfo.term.writeln('');

                        tabInfo.fitAddon.fit();
                        sendResize(sessionId, tabInfo.term.cols, tabInfo.term.rows);
                    }

                    // Phase C1-2: Register session
                    terminalSessions.set(sessionId, {
                        buffer: [],
                        tabId: pendingTabId || sessionId,
                        project: msg.project,
                        workspace: msg.workspace
                    });
                    activeSessionId = sessionId;
                    nativeTerminalReady = true;

                    // Notify Native with tabId
                    postToNative('terminal_ready', {
                        tab_id: pendingTabId || sessionId,
                        session_id: sessionId,
                        project: msg.project,
                        workspace: msg.workspace
                    });

                    // Clear pending spawn
                    pendingTerminalSpawn = null;

                    notifySwift('term_created', {
                        term_id: sessionId,
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
                        // Notify Native of successful save
                        notifyNativeSaved(msg.path);
                    } else if (!msg.success) {
                        // Notify Native of save error
                        notifyNativeSaveError(msg.path, msg.error || 'Save failed');
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
                // Phase C1-2: Clear terminal error state
                postToNative('terminal_connected', {});
            },
            onClose: () => {
                notifySwift('disconnected');
                // Phase C1-2: Mark all sessions as stale
                nativeTerminalReady = false;
                activeSessionId = null;
                terminalSessions.clear();
                postToNative('terminal_error', { message: 'Disconnected from core' });
            },
            onError: (e) => {
                notifySwift('error', { message: e.message || 'Connection failed' });
                // Phase C1-2: Notify Native of error
                nativeTerminalReady = false;
                postToNative('terminal_error', { message: e.message || 'Connection failed' });
            },
            onMessage: handleMessage
        });

        transport.connect();
    }

    function reconnect() {
        connect();
    }

    // ============================================
    // Native Bridge Handler (Phase B-3b)
    // ============================================

    // Handle events from Native (Swift) via tidyflowNative.receive()
    function handleNativeEvent(type, payload) {
        console.log('[NativeBridge] Handling event:', type, payload);

        switch (type) {
            case 'open_file': {
                const { project, workspace, path } = payload;
                if (!project || !workspace || !path) {
                    console.error('[NativeBridge] open_file missing required fields');
                    return;
                }
                // Switch to workspace if needed
                if (currentProject !== project || currentWorkspace !== workspace) {
                    currentProject = project;
                    currentWorkspace = workspace;
                }
                // Open file in editor
                openFileInEditor(path);
                break;
            }

            case 'save_file': {
                const { project, workspace, path } = payload;
                if (!path) {
                    console.error('[NativeBridge] save_file missing path');
                    postToNative('save_error', { path: '', message: 'Missing path' });
                    return;
                }
                // Find the editor tab and save
                const wsKey = getWorkspaceKey(project || currentProject, workspace || currentWorkspace);
                const tabId = 'editor-' + path.replace(/[^a-zA-Z0-9]/g, '-');

                if (workspaceTabs.has(wsKey)) {
                    const tabSet = workspaceTabs.get(wsKey);
                    if (tabSet.tabs.has(tabId)) {
                        saveEditorTab(tabId);
                    } else {
                        postToNative('save_error', { path, message: 'Editor tab not found' });
                    }
                } else {
                    postToNative('save_error', { path, message: 'Workspace not found' });
                }
                break;
            }

            // Phase C1-2: Mode switching (extended for diff in C2-1)
            case 'enter_mode': {
                const { mode } = payload;
                if (mode === 'terminal' || mode === 'editor' || mode === 'diff') {
                    setNativeMode(mode);
                } else {
                    console.warn('[NativeBridge] Unknown mode:', mode);
                }
                break;
            }

            // Phase C1-2: Spawn new terminal session for a tab
            case 'terminal_spawn': {
                const { project, workspace, tab_id } = payload;
                console.log('[NativeBridge] terminal_spawn:', tab_id, project, workspace);

                if (!transport || !transport.isConnected) {
                    postToNative('terminal_error', {
                        tab_id: tab_id,
                        message: 'Not connected to core'
                    });
                    return;
                }

                // Store pending spawn info to associate with term_created response
                pendingTerminalSpawn = { tabId: tab_id, project, workspace };

                // Request terminal creation from core
                createTerminal(project, workspace);
                break;
            }

            // Phase C1-2: Attach to existing terminal session
            case 'terminal_attach': {
                const { tab_id, session_id } = payload;
                console.log('[NativeBridge] terminal_attach:', tab_id, session_id);

                if (!terminalSessions.has(session_id)) {
                    // Session doesn't exist, need to respawn
                    postToNative('terminal_error', {
                        tab_id: tab_id,
                        message: 'Session not found, respawn needed'
                    });
                    return;
                }

                // Switch active session
                activeSessionId = session_id;
                nativeTerminalReady = true;

                // Find the terminal tab and replay buffer
                for (const [wsKey, tabSet] of workspaceTabs) {
                    if (tabSet.tabs.has(session_id)) {
                        const tab = tabSet.tabs.get(session_id);
                        if (tab.term) {
                            // Clear and replay buffer
                            tab.term.clear();
                            const session = terminalSessions.get(session_id);
                            if (session && session.buffer.length > 0) {
                                for (const line of session.buffer) {
                                    tab.term.write(line);
                                }
                            }
                            // Focus and fit
                            tab.term.focus();
                            if (tab.fitAddon) {
                                tab.fitAddon.fit();
                                sendResize(session_id, tab.term.cols, tab.term.rows);
                            }
                        }
                        switchToTab(session_id);
                        break;
                    }
                }

                // Notify Native
                const session = terminalSessions.get(session_id);
                postToNative('terminal_ready', {
                    tab_id: tab_id,
                    session_id: session_id,
                    project: session ? session.project : '',
                    workspace: session ? session.workspace : ''
                });
                break;
            }

            // Phase C1-2: Kill terminal session
            case 'terminal_kill': {
                const { tab_id, session_id } = payload;
                console.log('[NativeBridge] terminal_kill:', tab_id, session_id);

                // Remove session from tracking
                terminalSessions.delete(session_id);

                // If this was the active session, clear it
                if (activeSessionId === session_id) {
                    activeSessionId = null;
                }

                // Send kill to core
                if (transport && transport.isConnected) {
                    transport.send(JSON.stringify({
                        type: 'term_kill',
                        term_id: session_id
                    }));
                }

                // Notify Native
                postToNative('terminal_closed', {
                    tab_id: tab_id,
                    session_id: session_id,
                    code: 0
                });
                break;
            }

            // Phase C1-2: Legacy ensure terminal (backward compatibility)
            case 'terminal_ensure': {
                const { project, workspace } = payload;
                ensureTerminalForNative(project, workspace);
                break;
            }

            // Phase C2-1: Diff mode and open
            case 'diff_open': {
                const { project, workspace, path, mode } = payload;
                console.log('[NativeBridge] diff_open:', path, mode);

                if (!project || !workspace || !path) {
                    console.error('[NativeBridge] diff_open missing required fields');
                    postToNative('diff_error', { message: 'Missing required fields' });
                    return;
                }

                // Switch to workspace if needed
                if (currentProject !== project || currentWorkspace !== workspace) {
                    currentProject = project;
                    currentWorkspace = workspace;
                }

                // Open diff tab with specified mode
                openDiffTabFromNative(path, mode || 'working');
                break;
            }

            case 'diff_set_mode': {
                const { mode } = payload;
                console.log('[NativeBridge] diff_set_mode:', mode);

                // Update current diff tab's mode
                const wsKey = getCurrentWorkspaceKey();
                if (wsKey && workspaceTabs.has(wsKey)) {
                    const tabSet = workspaceTabs.get(wsKey);
                    const activeTab = tabSet.tabs.get(tabSet.activeTabId);
                    if (activeTab && activeTab.type === 'diff') {
                        activeTab.diffMode = mode;
                        sendGitDiff(activeTab.project, activeTab.workspace, activeTab.filePath, mode);
                    }
                }
                break;
            }

            // Phase C2-1.5: Reveal line in editor with highlight
            case 'editor_reveal_line': {
                const { path, line, highlightMs } = payload;
                console.log('[NativeBridge] editor_reveal_line:', path, line, highlightMs);

                if (!path || !line) {
                    console.error('[NativeBridge] editor_reveal_line missing required fields');
                    return;
                }

                // Find the editor tab for this path
                const wsKey = getCurrentWorkspaceKey();
                if (!wsKey || !workspaceTabs.has(wsKey)) {
                    console.warn('[NativeBridge] No workspace for editor_reveal_line');
                    return;
                }

                const tabId = 'editor-' + path.replace(/[^a-zA-Z0-9]/g, '-');
                const tabSet = workspaceTabs.get(wsKey);

                if (tabSet.tabs.has(tabId)) {
                    const tab = tabSet.tabs.get(tabId);
                    scrollToLineAndHighlight(tab, line, highlightMs || 2000);
                } else {
                    console.warn('[NativeBridge] Editor tab not found for:', path);
                }
                break;
            }

            default:
                console.warn('[NativeBridge] Unknown event type:', type);
        }
    }

    // Post event to Native (Swift)
    function postToNative(type, payload) {
        if (window.tidyflowNative && window.tidyflowNative.post) {
            window.tidyflowNative.post(type, payload || {});
        } else {
            console.warn('[NativeBridge] Native bridge not available');
        }
    }

    // Notify Native when file is saved successfully
    function notifyNativeSaved(path) {
        postToNative('saved', { path });
    }

    // Notify Native when save fails
    function notifyNativeSaveError(path, message) {
        postToNative('save_error', { path, message });
    }

    // ============================================
    // Phase C1-1: Native Mode Switching (extended C2-1)
    // ============================================

    /**
     * Set the native mode (editor, terminal, or diff)
     * This controls which UI elements are visible
     */
    function setNativeMode(mode) {
        if (nativeMode === mode) return;

        nativeMode = mode;
        console.log('[NativeMode] Switching to:', mode);

        // Update UI visibility
        const mainArea = document.getElementById('main-area');
        const leftSidebar = document.getElementById('left-sidebar');
        const rightPanel = document.getElementById('right-panel');

        if (mode === 'terminal') {
            // Terminal mode: hide sidebars, show only terminal
            if (leftSidebar) leftSidebar.style.display = 'none';
            if (rightPanel) rightPanel.style.display = 'none';
            // Hide all non-terminal tabs
            hideNonTerminalTabs();
            // Show terminal container
            showTerminalMode();
        } else if (mode === 'diff') {
            // Diff mode: hide sidebars, show only diff
            if (leftSidebar) leftSidebar.style.display = 'none';
            if (rightPanel) rightPanel.style.display = 'none';
            // Show diff mode
            showDiffMode();
        } else {
            // Editor mode: show sidebars
            if (leftSidebar) leftSidebar.style.display = 'flex';
            if (rightPanel) rightPanel.style.display = 'flex';
            // Show editor mode
            showEditorMode();
        }
    }

    /**
     * Hide non-terminal tabs when in terminal mode
     */
    function hideNonTerminalTabs() {
        const wsKey = getCurrentWorkspaceKey();
        if (!wsKey || !workspaceTabs.has(wsKey)) return;

        const tabSet = workspaceTabs.get(wsKey);
        tabSet.tabs.forEach((tab, tabId) => {
            if (tab.type !== 'terminal') {
                tab.pane.classList.remove('active');
                tab.tabEl.style.display = 'none';
            }
        });
    }

    /**
     * Show terminal mode UI
     */
    function showTerminalMode() {
        const wsKey = getCurrentWorkspaceKey();
        if (!wsKey || !workspaceTabs.has(wsKey)) return;

        const tabSet = workspaceTabs.get(wsKey);

        // Find first terminal tab
        let terminalTab = null;
        for (const [tabId, tab] of tabSet.tabs) {
            if (tab.type === 'terminal') {
                terminalTab = tab;
                break;
            }
        }

        if (terminalTab) {
            // Show and activate terminal tab
            terminalTab.tabEl.style.display = '';
            terminalTab.pane.classList.add('active');
            activeTabId = terminalTab.id;
            tabSet.activeTabId = terminalTab.id;

            // Fit and focus terminal
            setTimeout(() => {
                if (terminalTab.fitAddon) {
                    terminalTab.fitAddon.fit();
                }
                if (terminalTab.term) {
                    terminalTab.term.focus();
                    sendResize(terminalTab.termId, terminalTab.term.cols, terminalTab.term.rows);
                }
            }, 50);
        }

        // Hide placeholder
        if (placeholder) placeholder.style.display = 'none';
    }

    /**
     * Show editor mode UI
     */
    function showEditorMode() {
        const wsKey = getCurrentWorkspaceKey();
        if (!wsKey || !workspaceTabs.has(wsKey)) return;

        const tabSet = workspaceTabs.get(wsKey);

        // Show all tabs
        tabSet.tabs.forEach((tab) => {
            tab.tabEl.style.display = '';
        });

        // Restore active tab
        if (tabSet.activeTabId && tabSet.tabs.has(tabSet.activeTabId)) {
            switchToTab(tabSet.activeTabId);
        }
    }

    // ============================================
    // Phase C2-1: Diff Mode Functions
    // ============================================

    /**
     * Show diff mode UI
     */
    function showDiffMode() {
        const wsKey = getCurrentWorkspaceKey();
        if (!wsKey || !workspaceTabs.has(wsKey)) return;

        const tabSet = workspaceTabs.get(wsKey);

        // Hide non-diff tabs
        tabSet.tabs.forEach((tab, tabId) => {
            if (tab.type !== 'diff') {
                tab.pane.classList.remove('active');
                tab.tabEl.style.display = 'none';
            } else {
                tab.tabEl.style.display = '';
            }
        });

        // Find and activate first diff tab
        for (const [tabId, tab] of tabSet.tabs) {
            if (tab.type === 'diff') {
                switchToTab(tabId);
                break;
            }
        }
    }

    /**
     * Open diff tab from Native bridge
     * @param {string} path - File path to diff
     * @param {string} mode - 'working' or 'staged'
     */
    function openDiffTabFromNative(path, mode) {
        if (!currentProject || !currentWorkspace) {
            postToNative('diff_error', { message: 'No workspace selected' });
            return;
        }

        // Create or activate diff tab
        const tabInfo = createDiffTab(path, 'M');  // Default to 'M' (modified) code
        if (tabInfo) {
            // Set the diff mode
            tabInfo.diffMode = mode;

            // Update mode toggle UI
            const modeToggle = tabInfo.pane.querySelector('.diff-mode-toggle');
            if (modeToggle) {
                modeToggle.querySelectorAll('.diff-mode-btn').forEach(btn => {
                    btn.classList.toggle('active', btn.dataset.mode === mode);
                });
            }

            switchToTab(tabInfo.id);
            sendGitDiff(currentProject, currentWorkspace, path, mode);
        }
    }

    /**
     * Handle diff line click - open file in editor via Native
     * @param {string} path - File path
     * @param {number} line - Line number (optional)
     */
    function openFileAtLineViaNative(path, line) {
        postToNative('open_file_request', {
            workspace: currentWorkspace,
            path: path,
            line: line || null
        });
    }

    /**
     * Ensure a terminal exists for native mode (legacy compatibility)
     * Called when Native switches to terminal tab without specifying tabId
     */
    function ensureTerminalForNative(project, workspace) {
        console.log('[NativeMode] Ensuring terminal for:', project, workspace);

        // Ensure WebSocket is connected
        if (!transport || !transport.isConnected) {
            console.log('[NativeMode] WebSocket not connected, connecting...');
            connect();
            // Queue the terminal ensure for after connection
            setTimeout(() => ensureTerminalForNative(project, workspace), 500);
            return;
        }

        const wsKey = getWorkspaceKey(project, workspace);

        // Check if we already have a terminal for this workspace
        if (workspaceTabs.has(wsKey)) {
            const tabSet = workspaceTabs.get(wsKey);
            for (const [tabId, tab] of tabSet.tabs) {
                if (tab.type === 'terminal') {
                    // Terminal exists, activate it
                    activeSessionId = tab.termId;
                    nativeTerminalReady = true;
                    postToNative('terminal_ready', {
                        tab_id: tab.termId,
                        session_id: tab.termId,
                        project: project,
                        workspace: workspace
                    });
                    console.log('[NativeMode] Existing terminal found:', tab.termId);
                    return;
                }
            }
        }

        // No terminal exists, need to select workspace or create terminal
        if (currentProject !== project || currentWorkspace !== workspace) {
            // Select workspace first (this will create initial terminal)
            console.log('[NativeMode] Selecting workspace:', project, workspace);
            selectWorkspace(project, workspace);
        } else {
            // Same workspace, create new terminal
            console.log('[NativeMode] Creating new terminal');
            createTerminal(project, workspace);
        }
    }

    /**
     * Get current native mode
     */
    function getNativeMode() {
        return nativeMode;
    }

    /**
     * Check if terminal is ready for native
     */
    function isNativeTerminalReady() {
        return nativeTerminalReady;
    }

    /**
     * Get active session ID (Phase C1-2)
     */
    function getActiveSessionId() {
        return activeSessionId;
    }

    /**
     * Get all terminal sessions (Phase C1-2)
     */
    function getTerminalSessions() {
        return terminalSessions;
    }

    // Initialize native bridge event handler
    function initNativeBridge() {
        if (window.tidyflowNative) {
            window.tidyflowNative.onEvent = handleNativeEvent;
            // Notify Native that web is ready
            postToNative('ready', { capabilities: ['editor', 'terminal', 'diff'] });
            console.log('[NativeBridge] Bridge initialized and ready');
        } else {
            console.log('[NativeBridge] Native bridge not available (running in browser?)');
        }
    }

    // Initialize on load
    document.addEventListener('DOMContentLoaded', () => {
        initUI();
        // Initialize native bridge after UI
        setTimeout(initNativeBridge, 100);
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

        // Phase C1-1: Native mode API
        setNativeMode,
        getNativeMode,
        ensureTerminalForNative,
        isNativeTerminalReady,
    };
})();
