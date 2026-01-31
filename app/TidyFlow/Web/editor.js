/**
 * TidyFlow Editor - File editing within workspaces
 * Uses CodeMirror 6 for text editing
 */

(function() {
    'use strict';

    // Editor state
    let editorView = null;
    let currentFile = null;
    let isDirty = false;
    let currentProject = null;
    let currentWorkspace = null;
    let workspaceRoot = null;

    // DOM elements
    let fileListEl = null;
    let editorContainer = null;
    let statusBar = null;
    let fileNameEl = null;
    let saveBtn = null;

    // Base64 utilities
    function encodeBase64(str) {
        const encoder = new TextEncoder();
        const bytes = encoder.encode(str);
        let binary = '';
        for (let i = 0; i < bytes.length; i++) {
            binary += String.fromCharCode(bytes[i]);
        }
        return btoa(binary);
    }

    function decodeBase64(base64) {
        const binary = atob(base64);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) {
            bytes[i] = binary.charCodeAt(i);
        }
        return new TextDecoder().decode(bytes);
    }

    // Initialize editor UI
    function initEditorUI() {
        fileListEl = document.getElementById('file-list');
        editorContainer = document.getElementById('editor-container');
        statusBar = document.getElementById('editor-status');
        fileNameEl = document.getElementById('editor-filename');
        saveBtn = document.getElementById('editor-save');

        if (saveBtn) {
            saveBtn.addEventListener('click', saveFile);
        }

        // Keyboard shortcut for save
        document.addEventListener('keydown', (e) => {
            if ((e.metaKey || e.ctrlKey) && e.key === 's') {
                e.preventDefault();
                saveFile();
            }
        });
    }

    // Create CodeMirror editor instance
    function createEditor() {
        if (!editorContainer || !window.CodeMirror) {
            console.warn('CodeMirror not loaded or container not found');
            return;
        }

        // Basic CodeMirror 6 setup
        const { EditorView, basicSetup } = window.CodeMirror;

        editorView = new EditorView({
            doc: '',
            extensions: [
                basicSetup,
                EditorView.updateListener.of((update) => {
                    if (update.docChanged && currentFile) {
                        setDirty(true);
                    }
                }),
                EditorView.theme({
                    '&': {
                        height: '100%',
                        fontSize: '14px',
                    },
                    '.cm-scroller': {
                        fontFamily: 'Menlo, Monaco, "Courier New", monospace',
                    },
                    '.cm-content': {
                        caretColor: '#d4d4d4',
                    },
                    '&.cm-focused .cm-cursor': {
                        borderLeftColor: '#d4d4d4',
                    },
                }, { dark: true }),
            ],
            parent: editorContainer,
        });
    }

    // Set dirty state
    function setDirty(dirty) {
        isDirty = dirty;
        updateStatus();
    }

    // Update status bar
    function updateStatus() {
        if (fileNameEl) {
            let text = currentFile || 'No file open';
            if (isDirty) text += ' *';
            fileNameEl.textContent = text;
        }
        if (saveBtn) {
            saveBtn.disabled = !isDirty || !currentFile;
        }
    }

    // Show status message
    function showStatus(message, isError = false) {
        if (statusBar) {
            statusBar.textContent = message;
            statusBar.className = 'editor-status' + (isError ? ' error' : '');
            setTimeout(() => {
                statusBar.textContent = '';
                statusBar.className = 'editor-status';
            }, 3000);
        }
    }

    // Set workspace context
    function setWorkspace(project, workspace, root) {
        currentProject = project;
        currentWorkspace = workspace;
        workspaceRoot = root;

        // Clear current file
        currentFile = null;
        isDirty = false;
        if (editorView) {
            editorView.dispatch({
                changes: { from: 0, to: editorView.state.doc.length, insert: '' }
            });
        }
        updateStatus();

        // Refresh file list
        refreshFileList();
    }

    // Refresh file list
    function refreshFileList() {
        if (!currentProject || !currentWorkspace) {
            if (fileListEl) {
                fileListEl.innerHTML = '<div class="file-list-empty">No workspace selected</div>';
            }
            return;
        }

        // Request file list via WebSocket
        if (window.tidyflow && window.tidyflow.sendFileList) {
            window.tidyflow.sendFileList(currentProject, currentWorkspace, '.');
        }
    }

    // Handle file list response
    function handleFileList(project, workspace, path, items) {
        if (project !== currentProject || workspace !== currentWorkspace) {
            return;
        }

        if (!fileListEl) return;

        fileListEl.innerHTML = '';

        if (items.length === 0) {
            fileListEl.innerHTML = '<div class="file-list-empty">Empty directory</div>';
            return;
        }

        items.forEach(item => {
            const el = document.createElement('div');
            el.className = 'file-item' + (item.is_dir ? ' directory' : '');

            const icon = document.createElement('span');
            icon.className = 'file-icon';
            icon.textContent = item.is_dir ? '📁' : '📄';
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

                el.addEventListener('click', () => openFile(item.name));
            }

            fileListEl.appendChild(el);
        });
    }

    // Format file size
    function formatSize(bytes) {
        if (bytes < 1024) return bytes + ' B';
        if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
        return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
    }

    // Open file
    function openFile(path) {
        if (isDirty) {
            if (!confirm('Unsaved changes will be lost. Continue?')) {
                return;
            }
        }

        if (window.tidyflow && window.tidyflow.sendFileRead) {
            window.tidyflow.sendFileRead(currentProject, currentWorkspace, path);
        }
    }

    // Handle file read response
    function handleFileRead(project, workspace, path, content_b64, size) {
        if (project !== currentProject || workspace !== currentWorkspace) {
            return;
        }

        try {
            const content = decodeBase64(content_b64);
            currentFile = path;
            isDirty = false;

            if (editorView) {
                editorView.dispatch({
                    changes: { from: 0, to: editorView.state.doc.length, insert: content }
                });
            }

            updateStatus();
            showStatus('Opened: ' + path);
        } catch (e) {
            showStatus('Failed to decode file content', true);
        }
    }

    // Save file
    function saveFile() {
        if (!currentFile || !editorView) {
            return;
        }

        const content = editorView.state.doc.toString();
        const content_b64 = encodeBase64(content);

        if (window.tidyflow && window.tidyflow.sendFileWrite) {
            window.tidyflow.sendFileWrite(currentProject, currentWorkspace, currentFile, content_b64);
        }
    }

    // Handle file write response
    function handleFileWrite(project, workspace, path, success, size) {
        if (project !== currentProject || workspace !== currentWorkspace) {
            return;
        }

        if (success) {
            isDirty = false;
            updateStatus();
            showStatus('Saved: ' + path + ' (' + formatSize(size) + ')');
        } else {
            showStatus('Failed to save file', true);
        }
    }

    // Handle error
    function handleError(code, message) {
        showStatus('Error: ' + message, true);
    }

    // Initialize on load
    document.addEventListener('DOMContentLoaded', () => {
        initEditorUI();
        // Editor will be created when CodeMirror is loaded
        if (window.CodeMirror) {
            createEditor();
        }
    });

    // Expose API
    window.tidyflowEditor = {
        init: () => {
            initEditorUI();
            createEditor();
        },
        setWorkspace,
        refreshFileList,
        handleFileList,
        handleFileRead,
        handleFileWrite,
        handleError,
        getCurrentFile: () => currentFile,
        isDirty: () => isDirty,
    };
})();
