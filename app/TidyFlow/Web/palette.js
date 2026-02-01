/**
 * TidyFlow Command Palette
 * Cmd+P: Quick Open (file search)
 * Cmd+Shift+P: Command Palette (command search)
 */

(function() {
    'use strict';

    // ============================================
    // COMMAND REGISTRY
    // ============================================

    const commands = new Map();

    function registerCommand(id, config) {
        commands.set(id, {
            id,
            label: config.label,
            description: config.description || '',
            shortcut: config.shortcut || null,
            category: config.category || 'general',
            scope: config.scope || 'global', // 'global' or 'workspace'
            handler: config.handler
        });
    }

    function getCommands(scope) {
        const result = [];
        commands.forEach(cmd => {
            if (scope === 'all' || cmd.scope === 'global' || (cmd.scope === 'workspace' && scope === 'workspace')) {
                result.push(cmd);
            }
        });
        return result;
    }

    // ============================================
    // FILE INDEX (for Quick Open)
    // ============================================

    let fileIndex = [];
    let fileIndexWorkspaceKey = null;
    let fileIndexLoading = false;
    let fileIndexPendingCallback = null;

    function updateFileIndex(callback) {
        if (!window.tidyflow) {
            if (callback) callback([]);
            return;
        }

        const project = window.tidyflow.getCurrentProject();
        const workspace = window.tidyflow.getCurrentWorkspace();

        if (!project || !workspace) {
            fileIndex = [];
            fileIndexWorkspaceKey = null;
            if (callback) callback([]);
            return;
        }

        const wsKey = `${project}/${workspace}`;

        // Check if we have a cached index from the server
        const cachedIndex = window.tidyflow.getFileIndex(project, workspace);
        if (cachedIndex && cachedIndex.items) {
            fileIndex = cachedIndex.items;
            fileIndexWorkspaceKey = wsKey;
            if (callback) callback(fileIndex);
            return;
        }

        // Request file index from server
        fileIndexLoading = true;
        fileIndexPendingCallback = callback;
        window.tidyflow.sendFileIndex(project, workspace);
    }

    // Called by main.js when file_index_result arrives
    function onFileIndexReady(wsKey) {
        if (!window.tidyflow) return;

        const project = window.tidyflow.getCurrentProject();
        const workspace = window.tidyflow.getCurrentWorkspace();
        const currentWsKey = `${project}/${workspace}`;

        if (wsKey === currentWsKey) {
            const cachedIndex = window.tidyflow.getFileIndex(project, workspace);
            if (cachedIndex && cachedIndex.items) {
                fileIndex = cachedIndex.items;
                fileIndexWorkspaceKey = wsKey;
            }
        }

        fileIndexLoading = false;
        if (fileIndexPendingCallback) {
            fileIndexPendingCallback(fileIndex);
            fileIndexPendingCallback = null;
        }
    }

    function refreshFileIndex() {
        if (!window.tidyflow) return;

        const project = window.tidyflow.getCurrentProject();
        const workspace = window.tidyflow.getCurrentWorkspace();

        if (!project || !workspace) return;

        fileIndexWorkspaceKey = null;
        fileIndex = [];
        window.tidyflow.refreshFileIndex(project, workspace);
    }

    function getFileIndex() {
        return fileIndex;
    }

    function isFileIndexLoading() {
        return fileIndexLoading;
    }

    // ============================================
    // FUZZY SEARCH
    // ============================================

    function fuzzyMatch(query, text) {
        if (!query) return { match: true, score: 0, indices: [] };

        const lowerQuery = query.toLowerCase();
        const lowerText = text.toLowerCase();

        // Simple substring match with scoring
        const idx = lowerText.indexOf(lowerQuery);
        if (idx !== -1) {
            return {
                match: true,
                score: 100 - idx + (lowerQuery.length / lowerText.length) * 50,
                indices: [[idx, idx + lowerQuery.length]]
            };
        }

        // Character-by-character fuzzy match
        let queryIdx = 0;
        let score = 0;
        const indices = [];
        let lastMatchIdx = -1;

        for (let i = 0; i < lowerText.length && queryIdx < lowerQuery.length; i++) {
            if (lowerText[i] === lowerQuery[queryIdx]) {
                indices.push(i);
                // Bonus for consecutive matches
                if (lastMatchIdx === i - 1) {
                    score += 10;
                }
                // Bonus for matching at word boundaries
                if (i === 0 || lowerText[i - 1] === '/' || lowerText[i - 1] === '.' || lowerText[i - 1] === '-' || lowerText[i - 1] === '_') {
                    score += 5;
                }
                score += 1;
                lastMatchIdx = i;
                queryIdx++;
            }
        }

        if (queryIdx === lowerQuery.length) {
            return { match: true, score, indices: indices.map(i => [i, i + 1]) };
        }

        return { match: false, score: 0, indices: [] };
    }

    function highlightMatches(text, indices) {
        if (!indices || indices.length === 0) return escapeHtml(text);

        let result = '';
        let lastEnd = 0;

        // Merge overlapping indices
        const merged = [];
        indices.sort((a, b) => a[0] - b[0]);
        for (const [start, end] of indices) {
            if (merged.length > 0 && start <= merged[merged.length - 1][1]) {
                merged[merged.length - 1][1] = Math.max(merged[merged.length - 1][1], end);
            } else {
                merged.push([start, end]);
            }
        }

        for (const [start, end] of merged) {
            result += escapeHtml(text.substring(lastEnd, start));
            result += '<span class="palette-match">' + escapeHtml(text.substring(start, end)) + '</span>';
            lastEnd = end;
        }
        result += escapeHtml(text.substring(lastEnd));

        return result;
    }

    function escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }

    // ============================================
    // PALETTE UI
    // ============================================

    let paletteEl = null;
    let paletteInputEl = null;
    let paletteListEl = null;
    let paletteMode = 'command'; // 'command' or 'file'
    let paletteItems = [];
    let selectedIndex = 0;
    let isOpen = false;

    function createPaletteUI() {
        if (paletteEl) return;

        // Create overlay
        paletteEl = document.createElement('div');
        paletteEl.id = 'command-palette';
        paletteEl.className = 'palette-overlay';
        paletteEl.innerHTML = `
            <div class="palette-container">
                <div class="palette-input-wrapper">
                    <span class="palette-prefix"></span>
                    <input type="text" class="palette-input" placeholder="Type to search...">
                </div>
                <div class="palette-list"></div>
                <div class="palette-footer">
                    <span class="palette-hint">↑↓ Navigate</span>
                    <span class="palette-hint">↵ Select</span>
                    <span class="palette-hint">Esc Close</span>
                </div>
            </div>
        `;

        document.body.appendChild(paletteEl);

        paletteInputEl = paletteEl.querySelector('.palette-input');
        paletteListEl = paletteEl.querySelector('.palette-list');

        // Event listeners
        paletteEl.addEventListener('click', (e) => {
            if (e.target === paletteEl) {
                closePalette();
            }
        });

        paletteInputEl.addEventListener('input', () => {
            filterItems(paletteInputEl.value);
        });

        paletteInputEl.addEventListener('keydown', handlePaletteKeydown);
    }

    function openPalette(mode) {
        createPaletteUI();

        paletteMode = mode;
        isOpen = true;
        selectedIndex = 0;

        const prefixEl = paletteEl.querySelector('.palette-prefix');

        if (mode === 'command') {
            prefixEl.textContent = '>';
            paletteInputEl.placeholder = 'Type a command...';
            loadCommands();
        } else {
            prefixEl.textContent = '';
            paletteInputEl.placeholder = 'Type a file name...';
            loadFiles();
        }

        paletteEl.classList.add('open');
        paletteInputEl.value = '';
        paletteInputEl.focus();
    }

    function closePalette() {
        if (!paletteEl) return;
        paletteEl.classList.remove('open');
        isOpen = false;
        paletteItems = [];
    }

    function loadCommands() {
        const hasWorkspace = window.tidyflow &&
            window.tidyflow.getCurrentProject() &&
            window.tidyflow.getCurrentWorkspace();

        const scope = hasWorkspace ? 'workspace' : 'global';
        const availableCommands = getCommands(scope === 'workspace' ? 'all' : 'global');

        paletteItems = availableCommands.map(cmd => ({
            type: 'command',
            id: cmd.id,
            label: cmd.label,
            description: cmd.description,
            shortcut: cmd.shortcut,
            disabled: cmd.scope === 'workspace' && !hasWorkspace,
            handler: cmd.handler
        }));

        renderItems(paletteItems);
    }

    function loadFiles() {
        const hasWorkspace = window.tidyflow &&
            window.tidyflow.getCurrentProject() &&
            window.tidyflow.getCurrentWorkspace();

        if (!hasWorkspace) {
            paletteItems = [];
            paletteListEl.innerHTML = '<div class="palette-empty">Select a workspace first</div>';
            return;
        }

        // Check if we already have the index
        const project = window.tidyflow.getCurrentProject();
        const workspace = window.tidyflow.getCurrentWorkspace();
        const cachedIndex = window.tidyflow.getFileIndex(project, workspace);

        if (cachedIndex && cachedIndex.items && cachedIndex.items.length > 0) {
            // Use cached index
            fileIndex = cachedIndex.items;
            paletteItems = fileIndex.map(path => ({
                type: 'file',
                path: path,
                label: path.split('/').pop(),
                description: path
            }));
            renderItems(paletteItems);

            // Show truncation warning if applicable
            if (cachedIndex.truncated) {
                const warning = document.createElement('div');
                warning.className = 'palette-warning';
                warning.textContent = 'File list truncated (too many files)';
                paletteListEl.insertBefore(warning, paletteListEl.firstChild);
            }
            return;
        }

        // Show loading state and request index
        paletteListEl.innerHTML = '<div class="palette-loading">Loading file index...</div>';

        updateFileIndex((files) => {
            if (!isOpen || paletteMode !== 'file') return;

            if (files.length === 0) {
                paletteListEl.innerHTML = '<div class="palette-empty">No files found</div>';
                return;
            }

            paletteItems = files.map(path => ({
                type: 'file',
                path: path,
                label: path.split('/').pop(),
                description: path
            }));
            renderItems(paletteItems);
        });
    }

    function filterItems(query) {
        if (!query) {
            if (paletteMode === 'command') {
                loadCommands();
            } else {
                loadFiles();
            }
            return;
        }

        let filtered;
        if (paletteMode === 'command') {
            filtered = paletteItems
                .map(item => {
                    const result = fuzzyMatch(query, item.label);
                    return { ...item, ...result };
                })
                .filter(item => item.match)
                .sort((a, b) => b.score - a.score);
        } else {
            filtered = paletteItems
                .map(item => {
                    const result = fuzzyMatch(query, item.path || item.label);
                    return { ...item, ...result };
                })
                .filter(item => item.match)
                .sort((a, b) => b.score - a.score);
        }

        selectedIndex = 0;
        renderItems(filtered, query);
    }

    function renderItems(items, query = '') {
        if (items.length === 0) {
            paletteListEl.innerHTML = '<div class="palette-empty">No results found</div>';
            return;
        }

        paletteListEl.innerHTML = items.slice(0, 50).map((item, idx) => {
            const isSelected = idx === selectedIndex;
            const isDisabled = item.disabled;

            let labelHtml = item.label;
            let descHtml = item.description || '';

            if (query && item.indices) {
                if (paletteMode === 'file') {
                    descHtml = highlightMatches(item.description || item.path, item.indices);
                } else {
                    labelHtml = highlightMatches(item.label, item.indices);
                }
            }

            const shortcutHtml = item.shortcut ?
                `<span class="palette-shortcut">${formatShortcut(item.shortcut)}</span>` : '';

            const icon = item.type === 'file' ? getFileIcon(item.label) : '⌘';

            return `
                <div class="palette-item ${isSelected ? 'selected' : ''} ${isDisabled ? 'disabled' : ''}"
                     data-index="${idx}">
                    <span class="palette-icon">${icon}</span>
                    <div class="palette-item-content">
                        <span class="palette-label">${labelHtml}</span>
                        ${descHtml ? `<span class="palette-desc">${descHtml}</span>` : ''}
                    </div>
                    ${shortcutHtml}
                </div>
            `;
        }).join('');

        // Add click handlers
        paletteListEl.querySelectorAll('.palette-item').forEach(el => {
            el.addEventListener('click', () => {
                const idx = parseInt(el.dataset.index);
                selectItem(idx);
            });
        });
    }

    function selectItem(idx) {
        const items = paletteListEl.querySelectorAll('.palette-item');
        const item = items[idx];
        if (!item || item.classList.contains('disabled')) return;

        const data = paletteItems.find((_, i) => i === idx) ||
                     Array.from(items).map((el, i) => paletteItems[i])[idx];

        if (!data) return;

        closePalette();

        if (data.type === 'command' && data.handler) {
            data.handler();
        } else if (data.type === 'file' && data.path) {
            if (window.tidyflow && window.tidyflow.getCurrentProject()) {
                // Use the internal openFileInEditor function
                window.tidyflow.sendFileRead(
                    window.tidyflow.getCurrentProject(),
                    window.tidyflow.getCurrentWorkspace(),
                    data.path
                );
            }
        }
    }

    function handlePaletteKeydown(e) {
        const items = paletteListEl.querySelectorAll('.palette-item:not(.disabled)');
        const itemCount = items.length;

        switch (e.key) {
            case 'ArrowDown':
                e.preventDefault();
                selectedIndex = (selectedIndex + 1) % Math.max(1, itemCount);
                updateSelection();
                break;

            case 'ArrowUp':
                e.preventDefault();
                selectedIndex = (selectedIndex - 1 + itemCount) % Math.max(1, itemCount);
                updateSelection();
                break;

            case 'Enter':
                e.preventDefault();
                selectItem(selectedIndex);
                break;

            case 'Escape':
                e.preventDefault();
                closePalette();
                break;
        }
    }

    function updateSelection() {
        const items = paletteListEl.querySelectorAll('.palette-item');
        items.forEach((el, idx) => {
            el.classList.toggle('selected', idx === selectedIndex);
        });

        // Scroll into view
        const selected = items[selectedIndex];
        if (selected) {
            selected.scrollIntoView({ block: 'nearest' });
        }
    }

    function formatShortcut(shortcut) {
        if (!shortcut) return '';
        return shortcut
            .replace('Cmd', '⌘')
            .replace('Ctrl', '⌃')
            .replace('Alt', '⌥')
            .replace('Shift', '⇧')
            .replace(/\+/g, '');
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

    // ============================================
    // KEYBOARD SHORTCUTS
    // ============================================

    const shortcuts = new Map();

    function registerShortcut(key, handler, options = {}) {
        shortcuts.set(key, { handler, ...options });
    }

    function normalizeKey(e) {
        const parts = [];
        if (e.metaKey) parts.push('Cmd');
        if (e.ctrlKey) parts.push('Ctrl');
        if (e.altKey) parts.push('Alt');
        if (e.shiftKey) parts.push('Shift');

        let key = e.key;
        if (key === ' ') key = 'Space';
        if (key.length === 1) key = key.toUpperCase();

        parts.push(key);
        return parts.join('+');
    }

    function handleGlobalKeydown(e) {
        // Don't handle if palette is open (it has its own handler)
        if (isOpen && (e.key === 'ArrowUp' || e.key === 'ArrowDown' || e.key === 'Enter' || e.key === 'Escape')) {
            return;
        }

        const key = normalizeKey(e);
        const shortcut = shortcuts.get(key);

        if (shortcut) {
            // Check scope
            if (shortcut.scope === 'workspace') {
                const hasWorkspace = window.tidyflow &&
                    window.tidyflow.getCurrentProject() &&
                    window.tidyflow.getCurrentWorkspace();
                if (!hasWorkspace) return;
            }

            e.preventDefault();
            shortcut.handler();
        }
    }

    // ============================================
    // INITIALIZATION
    // ============================================

    function init() {
        // Register global shortcuts
        registerShortcut('Cmd+Shift+P', () => openPalette('command'));
        registerShortcut('Cmd+P', () => openPalette('file'));

        // Tool panel shortcuts (global)
        registerShortcut('Cmd+1', () => {
            if (window.tidyflow) window.tidyflow.switchToolView('explorer');
        });
        registerShortcut('Cmd+2', () => {
            if (window.tidyflow) window.tidyflow.switchToolView('search');
        });
        registerShortcut('Cmd+3', () => {
            if (window.tidyflow) window.tidyflow.switchToolView('git');
        });

        // Workspace-scoped shortcuts
        registerShortcut('Cmd+T', () => {
            if (window.tidyflow) {
                const proj = window.tidyflow.getCurrentProject();
                const ws = window.tidyflow.getCurrentWorkspace();
                if (proj && ws) {
                    window.tidyflow.createTerminal(proj, ws);
                }
            }
        }, { scope: 'workspace' });

        registerShortcut('Cmd+W', () => {
            if (window.tidyflow) {
                const tabId = window.tidyflow.getActiveTabId();
                if (tabId) {
                    window.tidyflow.closeTab(tabId);
                }
            }
        }, { scope: 'workspace' });

        registerShortcut('Ctrl+Tab', () => switchToNextTab(), { scope: 'workspace' });
        registerShortcut('Ctrl+Shift+Tab', () => switchToPrevTab(), { scope: 'workspace' });
        registerShortcut('Cmd+Alt+ArrowRight', () => switchToNextTab(), { scope: 'workspace' });
        registerShortcut('Cmd+Alt+ArrowLeft', () => switchToPrevTab(), { scope: 'workspace' });

        // Register commands
        registerCommand('palette.openCommandPalette', {
            label: 'Show All Commands',
            shortcut: 'Cmd+Shift+P',
            scope: 'global',
            handler: () => openPalette('command')
        });

        registerCommand('palette.quickOpen', {
            label: 'Quick Open File',
            shortcut: 'Cmd+P',
            scope: 'workspace',
            handler: () => openPalette('file')
        });

        registerCommand('view.explorer', {
            label: 'Show Explorer',
            shortcut: 'Cmd+1',
            scope: 'global',
            category: 'View',
            handler: () => window.tidyflow?.switchToolView('explorer')
        });

        registerCommand('view.search', {
            label: 'Show Search',
            shortcut: 'Cmd+2',
            scope: 'global',
            category: 'View',
            handler: () => window.tidyflow?.switchToolView('search')
        });

        registerCommand('view.git', {
            label: 'Show Git',
            shortcut: 'Cmd+3',
            scope: 'global',
            category: 'View',
            handler: () => window.tidyflow?.switchToolView('git')
        });

        registerCommand('terminal.new', {
            label: 'New Terminal',
            shortcut: 'Cmd+T',
            scope: 'workspace',
            category: 'Terminal',
            handler: () => {
                if (window.tidyflow) {
                    const proj = window.tidyflow.getCurrentProject();
                    const ws = window.tidyflow.getCurrentWorkspace();
                    if (proj && ws) window.tidyflow.createTerminal(proj, ws);
                }
            }
        });

        registerCommand('tab.close', {
            label: 'Close Tab',
            shortcut: 'Cmd+W',
            scope: 'workspace',
            category: 'Tab',
            handler: () => {
                if (window.tidyflow) {
                    const tabId = window.tidyflow.getActiveTabId();
                    if (tabId) window.tidyflow.closeTab(tabId);
                }
            }
        });

        registerCommand('tab.next', {
            label: 'Next Tab',
            shortcut: 'Ctrl+Tab',
            scope: 'workspace',
            category: 'Tab',
            handler: () => switchToNextTab()
        });

        registerCommand('tab.prev', {
            label: 'Previous Tab',
            shortcut: 'Ctrl+Shift+Tab',
            scope: 'workspace',
            category: 'Tab',
            handler: () => switchToPrevTab()
        });

        registerCommand('file.save', {
            label: 'Save File',
            shortcut: 'Cmd+S',
            scope: 'workspace',
            category: 'File',
            handler: () => {
                // This is handled in main.js already
                document.dispatchEvent(new KeyboardEvent('keydown', {
                    key: 's',
                    metaKey: true,
                    bubbles: true
                }));
            }
        });

        registerCommand('projects.refresh', {
            label: 'Refresh Projects',
            scope: 'global',
            category: 'Projects',
            handler: () => window.tidyflow?.listProjects()
        });

        registerCommand('explorer.refresh', {
            label: 'Refresh Explorer',
            scope: 'workspace',
            category: 'Explorer',
            handler: () => window.tidyflow?.refreshExplorer()
        });

        registerCommand('fileIndex.refresh', {
            label: 'Refresh File Index',
            scope: 'workspace',
            category: 'File',
            description: 'Rebuild the file index for Quick Open (Cmd+P)',
            handler: () => {
                refreshFileIndex();
            }
        });

        registerCommand('core.reconnect', {
            label: 'Reconnect to Core',
            scope: 'global',
            category: 'Connection',
            handler: () => window.tidyflow?.reconnect()
        });

        // Add global keydown listener
        document.addEventListener('keydown', handleGlobalKeydown);
    }

    function switchToNextTab() {
        if (!window.tidyflow) return;
        const tabs = window.tidyflow.getWorkspaceTabs();
        if (tabs.length === 0) return;

        const activeId = window.tidyflow.getActiveTabId();
        const currentIdx = tabs.findIndex(t => t.id === activeId);
        const nextIdx = (currentIdx + 1) % tabs.length;
        window.tidyflow.switchToTab(tabs[nextIdx].id);
    }

    function switchToPrevTab() {
        if (!window.tidyflow) return;
        const tabs = window.tidyflow.getWorkspaceTabs();
        if (tabs.length === 0) return;

        const activeId = window.tidyflow.getActiveTabId();
        const currentIdx = tabs.findIndex(t => t.id === activeId);
        const prevIdx = (currentIdx - 1 + tabs.length) % tabs.length;
        window.tidyflow.switchToTab(tabs[prevIdx].id);
    }

    // Initialize when DOM is ready
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

    // Expose API
    window.tidyflowPalette = {
        open: openPalette,
        close: closePalette,
        isOpen: () => isOpen,
        registerCommand,
        registerShortcut,
        updateFileIndex,
        refreshFileIndex,
        getFileIndex,
        isFileIndexLoading,
        onFileIndexReady
    };

})();
