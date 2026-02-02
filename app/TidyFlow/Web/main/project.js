/**
 * TidyFlow Main - Project Tree & Workspace Switching
 */
(function () {
  "use strict";

  const TF = window.TidyFlowApp;

  function renderProjectTree() {
    if (!TF.projectTree) return;
    TF.projectTree.innerHTML = "";

    TF.projects.forEach((proj) => {
      const projEl = document.createElement("div");
      projEl.className = "tree-item project";
      projEl.innerHTML = `<span class="tree-icon">📦</span><span class="tree-name">${proj.name}</span>`;
      projEl.addEventListener("click", () => TF.listWorkspaces(proj.name));
      TF.projectTree.appendChild(projEl);

      const wsItems = TF.workspacesMap.get(proj.name) || [];
      wsItems.forEach((ws) => {
        const wsEl = document.createElement("div");
        wsEl.className = "tree-item workspace";
        if (TF.currentProject === proj.name && TF.currentWorkspace === ws.name) {
          wsEl.classList.add("selected");
        }
        wsEl.innerHTML = `<span class="tree-icon">📁</span><span class="tree-name">${ws.name}</span>`;
        wsEl.addEventListener("click", (e) => {
          e.stopPropagation();
          TF.selectWorkspace(proj.name, ws.name);
        });
        TF.projectTree.appendChild(wsEl);
      });
    });
  }

  function switchWorkspaceUI(project, workspace, root) {
    const oldWsKey = TF.getCurrentWorkspaceKey();
    const newWsKey = TF.getWorkspaceKey(project, workspace);

    if (oldWsKey && TF.workspaceTabs.has(oldWsKey)) {
      const oldTabSet = TF.workspaceTabs.get(oldWsKey);
      oldTabSet.tabs.forEach((tab) => {
        tab.pane.classList.remove("active");
        tab.tabEl.style.display = "none";
      });
    }

    TF.currentProject = project;
    TF.currentWorkspace = workspace;
    TF.currentWorkspaceRoot = root;

    const newTabSet = TF.getOrCreateTabSet(newWsKey);
    newTabSet.tabs.forEach((tab) => {
      tab.tabEl.style.display = "";
    });

    if (newTabSet.activeTabId && newTabSet.tabs.has(newTabSet.activeTabId)) {
      TF.activeTabId = newTabSet.activeTabId;
      TF.switchToTab(TF.activeTabId);
    } else if (newTabSet.tabOrder.length > 0) {
      TF.switchToTab(newTabSet.tabOrder[0]);
    } else {
      TF.activeTabId = null;
      if (TF.placeholder) TF.placeholder.style.display = "flex";
    }

    TF.updateUIForWorkspace();
  }

  function updateUIForWorkspace() {
    const newTermBtn = document.getElementById("new-terminal-btn");
    if (newTermBtn) {
      newTermBtn.disabled = !TF.currentProject || !TF.currentWorkspace;
    }

    const searchInput = document.getElementById("search-input");
    if (searchInput) {
      searchInput.disabled = !TF.currentProject || !TF.currentWorkspace;
    }

    const gitRefreshBtn = document.getElementById("git-refresh-btn");
    if (gitRefreshBtn) {
      gitRefreshBtn.disabled = !TF.currentProject || !TF.currentWorkspace;
    }

    TF.renderProjectTree();

    TF.explorerTree.clear();
    TF.expandedDirs.clear();
    TF.allFilePaths = [];

    if (TF.activeToolView === "explorer") TF.refreshExplorer();
    else if (TF.activeToolView === "git") TF.refreshGitStatus();
  }

  TF.renderProjectTree = renderProjectTree;
  TF.switchWorkspaceUI = switchWorkspaceUI;
  TF.updateUIForWorkspace = updateUIForWorkspace;
})();
