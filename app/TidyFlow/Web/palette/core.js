/**
 * TidyFlow Palette - Core (commands, file index, fuzzy search)
 */
(function () {
  "use strict";

  window.TidyFlowPalette = window.TidyFlowPalette || {};
  const P = window.TidyFlowPalette;

  // Command registry
  P.commands = new Map();

  function registerCommand(id, config) {
    P.commands.set(id, {
      id,
      label: config.label,
      description: config.description || "",
      shortcut: config.shortcut || null,
      category: config.category || "general",
      scope: config.scope || "global",
      handler: config.handler,
    });
  }

  function getCommands(scope) {
    const result = [];
    P.commands.forEach((cmd) => {
      if (scope === "all" || cmd.scope === "global" || (cmd.scope === "workspace" && scope === "workspace")) {
        result.push(cmd);
      }
    });
    return result;
  }

  // File index
  P.fileIndex = [];
  P.fileIndexWorkspaceKey = null;
  P.fileIndexLoading = false;
  P.fileIndexPendingCallback = null;

  function updateFileIndex(callback) {
    if (!window.tidyflow) {
      if (callback) callback([]);
      return;
    }

    const project = window.tidyflow.getCurrentProject();
    const workspace = window.tidyflow.getCurrentWorkspace();

    if (!project || !workspace) {
      P.fileIndex = [];
      P.fileIndexWorkspaceKey = null;
      if (callback) callback([]);
      return;
    }

    const wsKey = `${project}/${workspace}`;

    const cachedIndex = window.tidyflow.getFileIndex(project, workspace);
    if (cachedIndex && cachedIndex.items) {
      P.fileIndex = cachedIndex.items;
      P.fileIndexWorkspaceKey = wsKey;
      if (callback) callback(P.fileIndex);
      return;
    }

    P.fileIndexLoading = true;
    P.fileIndexPendingCallback = callback;
    window.tidyflow.sendFileIndex(project, workspace);
  }

  function onFileIndexReady(wsKey) {
    if (!window.tidyflow) return;

    const project = window.tidyflow.getCurrentProject();
    const workspace = window.tidyflow.getCurrentWorkspace();
    const currentWsKey = `${project}/${workspace}`;

    if (wsKey === currentWsKey) {
      const cachedIndex = window.tidyflow.getFileIndex(project, workspace);
      if (cachedIndex && cachedIndex.items) {
        P.fileIndex = cachedIndex.items;
        P.fileIndexWorkspaceKey = wsKey;
      }
    }

    P.fileIndexLoading = false;
    if (P.fileIndexPendingCallback) {
      P.fileIndexPendingCallback(P.fileIndex);
      P.fileIndexPendingCallback = null;
    }
  }

  function refreshFileIndex() {
    if (!window.tidyflow) return;

    const project = window.tidyflow.getCurrentProject();
    const workspace = window.tidyflow.getCurrentWorkspace();

    if (!project || !workspace) return;

    P.fileIndexWorkspaceKey = null;
    P.fileIndex = [];
    window.tidyflow.refreshFileIndex(project, workspace);
  }

  function getFileIndex() {
    return P.fileIndex;
  }

  function isFileIndexLoading() {
    return P.fileIndexLoading;
  }

  // Fuzzy search
  function fuzzyMatch(query, text) {
    if (!query) return { match: true, score: 0, indices: [] };

    const lowerQuery = query.toLowerCase();
    const lowerText = text.toLowerCase();

    const idx = lowerText.indexOf(lowerQuery);
    if (idx !== -1) {
      return {
        match: true,
        score: 100 - idx + (lowerQuery.length / lowerText.length) * 50,
        indices: [[idx, idx + lowerQuery.length]],
      };
    }

    let queryIdx = 0;
    let score = 0;
    const indices = [];
    let lastMatchIdx = -1;

    for (let i = 0; i < lowerText.length && queryIdx < lowerQuery.length; i++) {
      if (lowerText[i] === lowerQuery[queryIdx]) {
        indices.push(i);
        if (lastMatchIdx === i - 1) score += 10;
        if (i === 0 || /[\/.\-_]/.test(lowerText[i - 1])) score += 5;
        score += 1;
        lastMatchIdx = i;
        queryIdx++;
      }
    }

    if (queryIdx === lowerQuery.length) {
      return { match: true, score, indices: indices.map((i) => [i, i + 1]) };
    }

    return { match: false, score: 0, indices: [] };
  }

  function escapeHtml(text) {
    const div = document.createElement("div");
    div.textContent = text;
    return div.innerHTML;
  }

  function highlightMatches(text, indices) {
    if (!indices || indices.length === 0) return escapeHtml(text);

    let result = "";
    let lastEnd = 0;

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
      result += '<span class="palette-match">' + escapeHtml(text.substring(start, end)) + "</span>";
      lastEnd = end;
    }
    result += escapeHtml(text.substring(lastEnd));

    return result;
  }

  P.registerCommand = registerCommand;
  P.getCommands = getCommands;
  P.updateFileIndex = updateFileIndex;
  P.onFileIndexReady = onFileIndexReady;
  P.refreshFileIndex = refreshFileIndex;
  P.getFileIndex = getFileIndex;
  P.isFileIndexLoading = isFileIndexLoading;
  P.fuzzyMatch = fuzzyMatch;
  P.escapeHtml = escapeHtml;
  P.highlightMatches = highlightMatches;
})();
