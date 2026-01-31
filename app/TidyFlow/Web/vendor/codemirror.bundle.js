/**
 * CodeMirror 6 - Minimal Bundle for TidyFlow
 * This is a simplified implementation for basic text editing.
 * For production, replace with the full CodeMirror 6 bundle.
 */

(function() {
    'use strict';

    // Simple text editor implementation
    class EditorState {
        constructor(config) {
            this.doc = new Doc(config.doc || '');
            this.extensions = config.extensions || [];
        }

        static create(config) {
            return new EditorState(config);
        }
    }

    class Doc {
        constructor(text) {
            this.text = text;
        }

        get length() {
            return this.text.length;
        }

        toString() {
            return this.text;
        }

        slice(from, to) {
            return this.text.slice(from, to);
        }
    }

    class EditorView {
        constructor(config) {
            this.parent = config.parent;
            this.state = EditorState.create({ doc: config.doc || '' });
            this.updateListeners = [];

            // Extract update listeners from extensions
            if (config.extensions) {
                config.extensions.forEach(ext => {
                    if (ext && ext._updateListener) {
                        this.updateListeners.push(ext._updateListener);
                    }
                });
            }

            this._createDOM();
            this._setupEvents();
        }

        _createDOM() {
            // Create editor structure
            this.dom = document.createElement('div');
            this.dom.className = 'cm-editor';

            this.scrollerEl = document.createElement('div');
            this.scrollerEl.className = 'cm-scroller';

            this.gutterEl = document.createElement('div');
            this.gutterEl.className = 'cm-gutters';

            this.lineNumbersEl = document.createElement('div');
            this.lineNumbersEl.className = 'cm-gutter cm-lineNumbers';
            this.gutterEl.appendChild(this.lineNumbersEl);

            this.contentEl = document.createElement('div');
            this.contentEl.className = 'cm-content';
            this.contentEl.setAttribute('contenteditable', 'true');
            this.contentEl.setAttribute('spellcheck', 'false');
            this.contentEl.style.whiteSpace = 'pre-wrap';
            this.contentEl.style.wordBreak = 'break-all';

            this.scrollerEl.appendChild(this.gutterEl);
            this.scrollerEl.appendChild(this.contentEl);
            this.dom.appendChild(this.scrollerEl);

            if (this.parent) {
                this.parent.appendChild(this.dom);
            }

            this._render();
        }

        _render() {
            const lines = this.state.doc.text.split('\n');

            // Update line numbers
            this.lineNumbersEl.innerHTML = '';
            lines.forEach((_, i) => {
                const lineNum = document.createElement('div');
                lineNum.className = 'cm-gutterElement';
                lineNum.textContent = (i + 1).toString();
                this.lineNumbersEl.appendChild(lineNum);
            });

            // Update content
            this.contentEl.textContent = this.state.doc.text;
        }

        _setupEvents() {
            this.contentEl.addEventListener('input', () => {
                const newText = this.contentEl.textContent || '';
                const oldDoc = this.state.doc;
                this.state.doc = new Doc(newText);

                // Notify listeners
                const update = {
                    docChanged: oldDoc.text !== newText,
                    state: this.state
                };
                this.updateListeners.forEach(fn => fn(update));

                // Re-render line numbers
                this._renderLineNumbers();
            });

            this.contentEl.addEventListener('keydown', (e) => {
                // Handle Tab key
                if (e.key === 'Tab') {
                    e.preventDefault();
                    document.execCommand('insertText', false, '    ');
                }
            });
        }

        _renderLineNumbers() {
            const lines = (this.contentEl.textContent || '').split('\n');
            this.lineNumbersEl.innerHTML = '';
            lines.forEach((_, i) => {
                const lineNum = document.createElement('div');
                lineNum.className = 'cm-gutterElement';
                lineNum.textContent = (i + 1).toString();
                this.lineNumbersEl.appendChild(lineNum);
            });
        }

        dispatch(transaction) {
            if (transaction.changes) {
                const { from, to, insert } = transaction.changes;
                const text = this.state.doc.text;
                const newText = text.slice(0, from) + insert + text.slice(to);
                this.state.doc = new Doc(newText);
                this._render();
            }
        }

        focus() {
            this.contentEl.focus();
        }

        destroy() {
            if (this.dom && this.dom.parentNode) {
                this.dom.parentNode.removeChild(this.dom);
            }
        }

        // Static helpers
        static updateListener = {
            of: (fn) => ({ _updateListener: fn })
        };

        static theme(spec, options) {
            // Theme is handled via CSS
            return {};
        }
    }

    // Basic setup (no-op for minimal implementation)
    const basicSetup = [];

    // Export to window
    window.CodeMirror = {
        EditorView,
        EditorState,
        basicSetup
    };
})();
