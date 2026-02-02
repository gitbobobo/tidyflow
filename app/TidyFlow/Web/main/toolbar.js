/**
 * TidyFlow Main - Tool Panel (已移除，保留空函数避免报错)
 * 侧边栏功能已由 Swift 端实现
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

  // 空函数 - 功能已移至 Swift 端
  function switchToolView() {}
  function refreshExplorer() {}
  function renderExplorerTree() {}
  function performSearch() {}
  function refreshGitStatus() {}
  function renderGitStatus() {}

  TF.getFileIcon = getFileIcon;
  TF.switchToolView = switchToolView;
  TF.refreshExplorer = refreshExplorer;
  TF.renderExplorerTree = renderExplorerTree;
  TF.performSearch = performSearch;
  TF.refreshGitStatus = refreshGitStatus;
  TF.renderGitStatus = renderGitStatus;
})();
