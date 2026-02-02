/**
 * TidyFlow Main - Workspace Switching
 */
(function () {
  "use strict";

  const TF = window.TidyFlowApp;

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
  }

  TF.switchWorkspaceUI = switchWorkspaceUI;
  TF.updateUIForWorkspace = updateUIForWorkspace;
})();
