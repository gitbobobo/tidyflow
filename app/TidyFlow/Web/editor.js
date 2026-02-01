/**
 * TidyFlow Editor - Legacy compatibility layer
 * Editor functionality is now integrated into main.js with workspace-scoped tabs
 * This file provides backward compatibility for any external code that references tidyflowEditor
 */

(function() {
    'use strict';

    // Expose minimal API for backward compatibility
    window.tidyflowEditor = {
        // These methods are now handled by main.js
        init: () => {
            console.log('Editor initialized (integrated into main.js)');
        },
        setWorkspace: (project, workspace, root) => {
            // Workspace switching is now handled by main.js
            console.log('setWorkspace called:', project, workspace);
        },
        refreshFileList: () => {
            if (window.tidyflow && window.tidyflow.refreshExplorer) {
                window.tidyflow.refreshExplorer();
            }
        },
        handleFileList: (project, workspace, path, items) => {
            // File list is now handled by main.js renderExplorerTree
        },
        handleFileRead: (project, workspace, path, content_b64, size) => {
            // File read is now handled by main.js createEditorTab
        },
        handleFileWrite: (project, workspace, path, success, size) => {
            // File write is now handled by main.js
        },
        handleError: (code, message) => {
            console.error('Editor error:', code, message);
        },
        getCurrentFile: () => {
            // Get current file from active editor tab
            if (window.tidyflow) {
                const tabs = window.tidyflow.getWorkspaceTabs();
                const activeId = window.tidyflow.getActiveTabId();
                const activeTab = tabs.find(t => t.id === activeId);
                return activeTab && activeTab.type === 'editor' ? activeTab.filePath : null;
            }
            return null;
        },
        isDirty: () => {
            if (window.tidyflow) {
                const tabs = window.tidyflow.getWorkspaceTabs();
                const activeId = window.tidyflow.getActiveTabId();
                const activeTab = tabs.find(t => t.id === activeId);
                return activeTab && activeTab.type === 'editor' ? activeTab.isDirty : false;
            }
            return false;
        },
    };
})();
