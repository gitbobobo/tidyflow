/**
 * TidyFlow Main - Connection, initUI, window.tidyflow export
 */
(function () {
  "use strict";

  const TF = window.TidyFlowApp;

  function initUI() {
    TF.tabBar = document.getElementById("tab-bar");
    TF.tabContent = document.getElementById("tab-content");
    TF.placeholder = document.getElementById("placeholder");
    TF.projectTree = document.getElementById("project-tree");

    const newTermBtn = document.getElementById("new-terminal-btn");
    if (newTermBtn) {
      newTermBtn.addEventListener("click", () => {
        if (TF.currentProject && TF.currentWorkspace) {
          TF.createTerminal(TF.currentProject, TF.currentWorkspace);
        }
      });
    }

    const refreshBtn = document.getElementById("refresh-projects");
    if (refreshBtn) {
      refreshBtn.addEventListener("click", TF.listProjects);
    }

    document.querySelectorAll(".tool-icon").forEach((icon) => {
      icon.addEventListener("click", () => TF.switchToolView(icon.dataset.tool));
    });

    const searchInput = document.getElementById("search-input");
    if (searchInput) {
      searchInput.addEventListener("input", (e) => TF.performSearch(e.target.value));
    }

    const gitRefreshBtn = document.getElementById("git-refresh-btn");
    if (gitRefreshBtn) {
      gitRefreshBtn.addEventListener("click", TF.refreshGitStatus);
    }

    document.addEventListener("keydown", (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "s") {
        e.preventDefault();
        TF.saveCurrentEditor();
      }
    });
  }

  function connect(retryCount = 0) {
    if (!window.TIDYFLOW_WS_URL && retryCount < 10) {
      setTimeout(() => connect(retryCount + 1), 50);
      return;
    }

    const wsURL = window.TIDYFLOW_WS_URL || "ws://127.0.0.1:47999/ws";

    if (TF.transport) TF.transport.close();

    console.log("Connecting to " + wsURL);

    TF.transport = new TF.WebSocketTransport(wsURL, {
      onOpen: () => {
        TF.notifySwift("connected");
        TF.postToNative("terminal_connected", {});
      },
      onClose: () => {
        TF.notifySwift("disconnected");
        TF.nativeTerminalReady = false;
        TF.activeSessionId = null;
        TF.terminalSessions.clear();
        TF.postToNative("terminal_error", { message: "Disconnected from core" });
      },
      onError: (e) => {
        TF.notifySwift("error", { message: e.message || "Connection failed" });
        TF.nativeTerminalReady = false;
        TF.postToNative("terminal_error", {
          message: e.message || "Connection failed",
        });
      },
      onMessage: TF.handleMessage,
    });

    TF.transport.connect();
  }

  function reconnect() {
    connect();
  }

  function initNativeBridge() {
    if (window.tidyflowNative) {
      window.tidyflowNative.onEvent = TF.handleNativeEvent;
      TF.postToNative("ready", { capabilities: ["editor", "terminal", "diff"] });
      console.log("[NativeBridge] Bridge initialized and ready");
    } else {
      console.log("[NativeBridge] Native bridge not available (running in browser?)");
    }
  }

  document.addEventListener("DOMContentLoaded", () => {
    initUI();
    setTimeout(initNativeBridge, 100);
  });

  window.tidyflow = {
    connect,
    reconnect,
    getActiveTabId: () => TF.activeTabId,
    getProtocolVersion: () => TF.protocolVersion,
    getCapabilities: () => TF.capabilities,

    listProjects: TF.listProjects,
    listWorkspaces: TF.listWorkspaces,
    selectWorkspace: TF.selectWorkspace,

    createTerminal: TF.createTerminal,
    listTerminals: TF.listTerminals,
    closeTab: TF.closeTab,
    switchToTab: TF.switchToTab,

    sendFileList: TF.sendFileList,
    sendFileRead: TF.sendFileRead,
    sendFileWrite: TF.sendFileWrite,
    sendFileIndex: TF.sendFileIndex,

    getFileIndex: (project, workspace) => {
      const wsKey = TF.getWorkspaceKey(project, workspace);
      return TF.workspaceFileIndex.get(wsKey) || null;
    },
    refreshFileIndex: (project, workspace) => {
      const wsKey = TF.getWorkspaceKey(project, workspace);
      TF.workspaceFileIndex.delete(wsKey);
      TF.sendFileIndex(project, workspace);
    },

    getProjects: () => TF.projects,
    getWorkspacesMap: () => TF.workspacesMap,
    getCurrentProject: () => TF.currentProject,
    getCurrentWorkspace: () => TF.currentWorkspace,
    getCurrentWorkspaceRoot: () => TF.currentWorkspaceRoot,

    getWorkspaceTabs: () => {
      const wsKey = TF.getCurrentWorkspaceKey();
      if (!wsKey || !TF.workspaceTabs.has(wsKey)) return [];
      const tabSet = TF.workspaceTabs.get(wsKey);
      return tabSet.tabOrder.map((id) => {
        const tab = tabSet.tabs.get(id);
        return {
          id: tab.id,
          type: tab.type,
          title: tab.title,
          filePath: tab.filePath,
          isDirty: tab.isDirty,
        };
      });
    },

    switchToolView: TF.switchToolView,
    refreshExplorer: TF.refreshExplorer,
    refreshGitStatus: TF.refreshGitStatus,

    getAllFilePaths: () => TF.allFilePaths,

    setNativeMode: TF.setNativeMode,
    getNativeMode: () => TF.nativeMode,
    ensureTerminalForNative: TF.ensureTerminalForNative,
    isNativeTerminalReady: () => TF.nativeTerminalReady,
  };

  TF.connect = connect;
  TF.reconnect = reconnect;
})();
