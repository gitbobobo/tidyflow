/**
 * CodeMirror 6 Bundle for TidyFlow
 * 包含核心编辑器和常用语言支持
 */

// 核心模块
import { EditorView, basicSetup } from "codemirror";
import { EditorState, StateEffect, StateField } from "@codemirror/state";
import { Decoration } from "@codemirror/view";

// 主题
import { oneDark } from "@codemirror/theme-one-dark";

// 语言支持
import { javascript } from "@codemirror/lang-javascript";
import { rust } from "@codemirror/lang-rust";
import { python } from "@codemirror/lang-python";
import { json } from "@codemirror/lang-json";
import { html } from "@codemirror/lang-html";
import { css } from "@codemirror/lang-css";
import { markdown } from "@codemirror/lang-markdown";
import { yaml } from "@codemirror/lang-yaml";

// 语言扩展映射
const languageExtensions = {
  // JavaScript/TypeScript
  js: () => javascript(),
  jsx: () => javascript({ jsx: true }),
  ts: () => javascript({ typescript: true }),
  tsx: () => javascript({ jsx: true, typescript: true }),
  mjs: () => javascript(),
  cjs: () => javascript(),

  // Rust
  rs: () => rust(),

  // Swift - 使用 Rust 语法作为近似（结构相似）
  swift: () => rust(),

  // Python
  py: () => python(),
  pyw: () => python(),

  // JSON
  json: () => json(),
  jsonc: () => json(),

  // HTML
  html: () => html(),
  htm: () => html(),

  // CSS
  css: () => css(),

  // Markdown
  md: () => markdown(),
  markdown: () => markdown(),

  // YAML
  yaml: () => yaml(),
  yml: () => yaml(),

  // TOML - 使用 YAML 作为近似
  toml: () => yaml(),
};

/**
 * 根据文件路径获取语言扩展
 * @param {string} filePath - 文件路径
 * @returns {Extension|null} - CodeMirror 语言扩展或 null
 */
function getLanguageExtension(filePath) {
  if (!filePath) return null;

  const ext = filePath.split(".").pop()?.toLowerCase();
  if (!ext) return null;

  const factory = languageExtensions[ext];
  return factory ? factory() : null;
}

// 导出到全局
window.CodeMirror = {
  EditorView,
  EditorState,
  basicSetup,
  getLanguageExtension,
  // 主题
  oneDark,
  // 用于行高亮等装饰功能
  Decoration,
  StateEffect,
  StateField,
  // 导出语言工厂函数供直接使用
  languages: {
    javascript,
    rust,
    python,
    json,
    html,
    css,
    markdown,
    yaml,
  },
};
