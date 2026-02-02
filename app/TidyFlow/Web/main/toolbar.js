/**
 * TidyFlow Main - Tool Panel (Explorer/Search/Git)
 */
(function () {
  "use strict";

  const TF = window.TidyFlowApp;

  function getFileIcon(filename) {
    const ext = filename.split(".").pop().toLowerCase();
    const icons = {
      js: "📜", ts: "📘", jsx: "⚛️", tsx: "⚛️", html: "🌐", css: "🎨",
      json: "📋", md: "📝", txt: "📄", rs: "🦀", go: "🐹", py: "🐍",
      swift: "🍎", java: "☕", png: "🖼️", jpg: "🖼️", gif: "🖼️", svg: "🖼️",
    };
    return icons[ext] || "📄";
  }

  function formatSize(bytes) {
    if (bytes < 1024) return bytes + " B";
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
    return (bytes / (1024 * 1024)).toFixed(1) + " MB";
  }

  function updateFilePathsCache() {
    TF.allFilePaths = [];
    function collectPaths(path, items) {
      items.forEach((item) => {
        const fullPath = path === "." ? item.name : `${path}/${item.name}`;
        if (!item.is_dir) TF.allFilePaths.push(fullPath);
        if (item.is_dir && TF.explorerTree.has(fullPath)) {
          collectPaths(fullPath, TF.explorerTree.get(fullPath));
        }
      });
    }
    if (TF.explorerTree.has(".")) {
      collectPaths(".", TF.explorerTree.get("."));
    }
  }

  function switchToolView(toolName) {
    TF.activeToolView = toolName;
    document.querySelectorAll(".tool-icon").forEach((icon) => {
      icon.classList.toggle("active", icon.dataset.tool === toolName);
    });
    document.querySelectorAll(".tool-view").forEach((view) => {
      view.classList.toggle("active", view.id === `${toolName}-view`);
    });
    if (toolName === "explorer") TF.refreshExplorer();
    if (toolName === "git") TF.refreshGitStatus();
  }

  function refreshExplorer() {
    const explorerTreeEl = document.getElementById("explorer-tree");
    if (!explorerTreeEl) return;
    if (!TF.currentProject || !TF.currentWorkspace) {
      explorerTreeEl.innerHTML = '<div class="file-empty">No workspace selected</div>';
      return;
    }
    TF.sendFileList(TF.currentProject, TF.currentWorkspace, ".");
  }

  function renderExplorerTree(path, items) {
    const explorerTreeEl = document.getElementById("explorer-tree");
    if (!explorerTreeEl) return;

    TF.explorerTree.set(path, items);

    if (path === ".") {
      explorerTreeEl.innerHTML = "";
      if (items.length === 0) {
        explorerTreeEl.innerHTML = '<div class="file-empty">Empty directory</div>';
        return;
      }
      items.forEach((item) => {
        explorerTreeEl.appendChild(createFileItem(item, "."));
      });
    } else {
      const parentEl = explorerTreeEl.querySelector(`[data-path="${path}"]`);
      if (parentEl) {
        let childrenEl = parentEl.querySelector(".file-children");
        if (!childrenEl) {
          childrenEl = document.createElement("div");
          childrenEl.className = "file-children";
          parentEl.appendChild(childrenEl);
        }
        childrenEl.innerHTML = "";
        items.forEach((item) => {
          childrenEl.appendChild(createFileItem(item, path));
        });
      }
    }
    updateFilePathsCache();
  }

  function createFileItem(item, parentPath) {
    const fullPath = parentPath === "." ? item.name : `${parentPath}/${item.name}`;
    const el = document.createElement("div");
    el.className = "file-item" + (item.is_dir ? " directory" : "");
    el.dataset.path = fullPath;

    const icon = document.createElement("span");
    icon.className = "file-icon";
    icon.textContent = item.is_dir ? "▶" : getFileIcon(item.name);
    el.appendChild(icon);

    const name = document.createElement("span");
    name.className = "file-name";
    name.textContent = item.name;
    el.appendChild(name);

    if (!item.is_dir) {
      const size = document.createElement("span");
      size.className = "file-size";
      size.textContent = formatSize(item.size);
      el.appendChild(size);
    }

    el.addEventListener("click", (e) => {
      e.stopPropagation();
      if (item.is_dir) toggleDirectory(el, fullPath);
      else TF.openFileInEditor(fullPath);
    });

    if (item.is_dir && TF.expandedDirs.has(fullPath)) {
      el.classList.add("expanded");
      const childrenEl = document.createElement("div");
      childrenEl.className = "file-children";
      el.appendChild(childrenEl);
      TF.sendFileList(TF.currentProject, TF.currentWorkspace, fullPath);
    }

    return el;
  }

  function toggleDirectory(el, path) {
    if (TF.expandedDirs.has(path)) {
      TF.expandedDirs.delete(path);
      el.classList.remove("expanded");
      const childrenEl = el.querySelector(".file-children");
      if (childrenEl) childrenEl.remove();
    } else {
      TF.expandedDirs.add(path);
      el.classList.add("expanded");
      const childrenEl = document.createElement("div");
      childrenEl.className = "file-children";
      childrenEl.innerHTML = '<div class="file-empty">Loading...</div>';
      el.appendChild(childrenEl);
      TF.sendFileList(TF.currentProject, TF.currentWorkspace, path);
    }
  }

  function performSearch(query) {
    const resultsEl = document.getElementById("search-results");
    if (!resultsEl) return;

    if (!query.trim()) {
      resultsEl.innerHTML = '<div class="search-empty">Enter a search term</div>';
      return;
    }

    const lowerQuery = query.toLowerCase();
    const matches = TF.allFilePaths.filter((p) => p.toLowerCase().includes(lowerQuery));

    if (matches.length === 0) {
      resultsEl.innerHTML = '<div class="search-empty">No files found</div>';
      return;
    }

    resultsEl.innerHTML = "";
    matches.slice(0, 50).forEach((path) => {
      const el = document.createElement("div");
      el.className = "search-result";

      const icon = document.createElement("span");
      icon.className = "file-icon";
      icon.textContent = getFileIcon(path);
      el.appendChild(icon);

      const name = document.createElement("span");
      name.className = "file-name";
      const idx = path.toLowerCase().indexOf(lowerQuery);
      name.innerHTML =
        path.substring(0, idx) +
        '<span class="match">' + path.substring(idx, idx + query.length) + "</span>" +
        path.substring(idx + query.length);
      el.appendChild(name);

      el.addEventListener("click", () => TF.openFileInEditor(path));
      resultsEl.appendChild(el);
    });
  }

  function refreshGitStatus() {
    const listEl = document.getElementById("git-status-list");
    if (!listEl) return;

    if (!TF.currentProject || !TF.currentWorkspace) {
      listEl.innerHTML = '<div class="git-empty">No workspace selected</div>';
      return;
    }

    listEl.innerHTML = '<div class="git-empty">Loading...</div>';
    TF.sendControlMessage({
      type: "git_status",
      project: TF.currentProject,
      workspace: TF.currentWorkspace,
    });
  }

  function renderGitStatus(repoRoot, items) {
    const listEl = document.getElementById("git-status-list");
    const headerEl = document.getElementById("git-repo-header");
    if (!listEl) return;

    if (headerEl) {
      if (repoRoot) {
        headerEl.textContent = repoRoot.split("/").pop() || "Repository";
        headerEl.title = repoRoot;
      } else {
        headerEl.textContent = "Not a git repo";
        headerEl.title = "";
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

    listEl.innerHTML = "";
    items.forEach((item) => {
      const el = document.createElement("div");
      el.className = "git-item";

      const status = document.createElement("span");
      status.className = "git-status";
      status.textContent = item.code;
      if (item.code === "M") status.classList.add("modified");
      else if (item.code === "A") status.classList.add("added");
      else if (item.code === "D") status.classList.add("deleted");
      else if (item.code === "??" || item.code === "?") status.classList.add("untracked");
      else if (item.code === "R" || item.code === "C") status.classList.add("renamed");
      el.appendChild(status);

      const file = document.createElement("span");
      file.className = "git-file";
      file.textContent = item.path;
      if (item.orig_path) file.title = `Renamed from: ${item.orig_path}`;
      el.appendChild(file);

      el.addEventListener("click", () => TF.openDiffTab(item.path, item.code));
      listEl.appendChild(el);
    });
  }

  TF.getFileIcon = getFileIcon;
  TF.switchToolView = switchToolView;
  TF.refreshExplorer = refreshExplorer;
  TF.renderExplorerTree = renderExplorerTree;
  TF.performSearch = performSearch;
  TF.refreshGitStatus = refreshGitStatus;
  TF.renderGitStatus = renderGitStatus;
})();
