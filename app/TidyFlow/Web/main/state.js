/**
 * TidyFlow Main - State & Utilities
 * Shared state variables, WebSocketTransport, notifySwift
 */
(function () {
  "use strict";

  window.TidyFlowApp = window.TidyFlowApp || {};
  const TF = window.TidyFlowApp;

  // UX-1: Renderer-only mode flag
  window.TIDYFLOW_RENDERER_ONLY = false;

  window.setRendererOnly = function (enabled) {
    window.TIDYFLOW_RENDERER_ONLY = enabled;
    if (enabled) {
      document.body.classList.add("renderer-only");
      console.log("[TidyFlow] Renderer-only mode enabled");
    } else {
      document.body.classList.remove("renderer-only");
      console.log("[TidyFlow] Renderer-only mode disabled");
    }
  };

  class WebSocketTransport {
    constructor(url, callbacks) {
      this.url = url;
      this.callbacks = callbacks;
      this.ws = null;
    }
    connect() {
      try {
        this.ws = new WebSocket(this.url);
        this.ws.binaryType = 'arraybuffer';
        this.ws.onopen = () => this.callbacks.onOpen();
        this.ws.onclose = () => this.callbacks.onClose();
        this.ws.onerror = (e) => this.callbacks.onError(e);
        this.ws.onmessage = (e) => {
          if (e.data instanceof ArrayBuffer) {
            const decoded = MessagePack.decode(new Uint8Array(e.data));
            this.callbacks.onMessage(decoded);
          } else {
            this.callbacks.onMessage(e.data);
          }
        };
      } catch (err) {
        this.callbacks.onError(err);
      }
    }
    send(data) {
      if (this.ws && this.ws.readyState === WebSocket.OPEN) {
        const encoded = MessagePack.encode(data);
        this.ws.send(encoded.buffer);
      }
    }
    close() {
      if (this.ws) this.ws.close();
    }
    get isConnected() {
      return this.ws && this.ws.readyState === WebSocket.OPEN;
    }
  }

  function notifySwift(type, data) {
    if (
      window.webkit &&
      window.webkit.messageHandlers &&
      window.webkit.messageHandlers.tidyflow
    ) {
      window.webkit.messageHandlers.tidyflow.postMessage({ type, ...data });
    }
  }

  // State
  TF.transport = null;
  TF.protocolVersion = 0;
  TF.capabilities = [];
  TF.nativeMode = "editor";
  TF.nativeTerminalReady = false;
  TF.defaultServerTerminalId = null;
  TF.pendingOutputBuffer = [];
  TF.terminalSessions = new Map();
  TF.activeSessionId = null;
  TF.pendingTerminalSpawn = null;
  TF.MAX_BUFFER_LINES = 2000;

  TF.projects = [];
  TF.workspacesMap = new Map();
  TF.currentProject = null;
  TF.currentWorkspace = null;
  TF.currentWorkspaceRoot = null;

  TF.workspaceTabs = new Map();
  TF.tabCounter = 0;
  TF.activeTabId = null;

  TF.workspaceFileIndex = new Map();

  TF.tabBar = null;
  TF.tabContent = null;
  TF.placeholder = null;
  TF.pendingLineNavigation = null;
  TF.pendingFileOpen = null;  // 待打开的文件（WebSocket 连接后处理）
  TF.pendingReloads = new Map();  // 追踪正在重新加载的文件 Map<filePath, { tabId, wsKey }>

  TF.WebSocketTransport = WebSocketTransport;
  TF.notifySwift = notifySwift;

  TF.getWorkspaceKey = function (project, workspace) {
    return `${project}/${workspace}`;
  };

  TF.getCurrentWorkspaceKey = function () {
    if (!TF.currentProject || !TF.currentWorkspace) return null;
    return TF.getWorkspaceKey(TF.currentProject, TF.currentWorkspace);
  };

  TF.getOrCreateTabSet = function (wsKey) {
    if (!TF.workspaceTabs.has(wsKey)) {
      TF.workspaceTabs.set(wsKey, {
        tabs: new Map(),
        activeTabId: null,
        tabOrder: [],
      });
    }
    return TF.workspaceTabs.get(wsKey);
  };
})();
