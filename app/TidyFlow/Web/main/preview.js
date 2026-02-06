/**
 * TidyFlow Main - Markdown Preview
 * 支持 GFM 表格、任务列表、代码高亮、Mermaid 流程图、相对路径图片
 */
(function () {
  "use strict";

  const TF = window.TidyFlowApp;

  // 待加载的图片 Map<filePath, Set<HTMLImageElement>>
  TF._pendingImageLoads = new Map();

  let markedInitialized = false;
  let mermaidInitialized = false;
  let mermaidCounter = 0;

  /**
   * 检测是否为 Markdown 文件
   */
  function isMarkdownFile(filePath) {
    if (!filePath) return false;
    const lower = filePath.toLowerCase();
    return lower.endsWith(".md") || lower.endsWith(".markdown");
  }

  /**
   * 初始化 marked.js 配置
   */
  function initMarked() {
    if (markedInitialized || !window.marked) return;

    const renderer = new marked.Renderer();

    // 自定义 code 渲染器：Mermaid 代码块输出专用容器
    const originalCode = renderer.code.bind(renderer);
    renderer.code = function ({ text, lang }) {
      if (lang === "mermaid") {
        return '<div class="mermaid">' + text + "</div>";
      }
      // 使用 highlight.js 高亮
      if (window.hljs && lang && hljs.getLanguage(lang)) {
        try {
          const highlighted = hljs.highlight(text, { language: lang }).value;
          return (
            '<pre><code class="hljs language-' +
            lang +
            '">' +
            highlighted +
            "</code></pre>"
          );
        } catch (_) {
          // 回退到默认
        }
      }
      // 无语言或不支持的语言，尝试自动检测
      if (window.hljs) {
        try {
          const auto = hljs.highlightAuto(text).value;
          return '<pre><code class="hljs">' + auto + "</code></pre>";
        } catch (_) {
          // 回退
        }
      }
      const escaped = text
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;");
      return "<pre><code>" + escaped + "</code></pre>";
    };

    // 自定义 image 渲染器：相对路径使用占位符
    renderer.image = function ({ href, title, text }) {
      if (!href) return "";
      // 绝对 URL 直接使用
      if (/^https?:\/\//i.test(href) || /^data:/i.test(href)) {
        const titleAttr = title ? ' title="' + title + '"' : "";
        return (
          '<img src="' + href + '" alt="' + (text || "") + '"' + titleAttr + " />"
        );
      }
      // 相对路径：输出占位符，后续异步加载
      const titleAttr = title ? ' title="' + title + '"' : "";
      return (
        '<img data-relative-src="' +
        href +
        '" alt="' +
        (text || "") +
        '"' +
        titleAttr +
        ' class="md-image-loading" />'
      );
    };

    marked.setOptions({
      renderer,
      gfm: true,
      breaks: true,
    });

    markedInitialized = true;
  }

  /**
   * 初始化 Mermaid（暗色主题）
   */
  function initMermaid() {
    if (mermaidInitialized || !window.mermaid) return;
    mermaid.initialize({
      startOnLoad: false,
      theme: "dark",
      securityLevel: "loose",
    });
    mermaidInitialized = true;
  }

  /**
   * 切换编辑/预览模式
   */
  function toggleMarkdownPreview(tabId) {
    const wsKey = TF.getCurrentWorkspaceKey();
    if (!wsKey) return;
    const tabSet = TF.workspaceTabs.get(wsKey);
    if (!tabSet) return;
    const tab = tabSet.tabs.get(tabId);
    if (!tab || tab.type !== "editor") return;

    const editorContainer = tab.pane.querySelector(".editor-container");
    const previewContainer = tab.previewContainer;
    if (!editorContainer || !previewContainer) return;

    if (!tab.previewMode) {
      // 编辑 → 预览
      editorContainer.style.display = "none";
      previewContainer.style.display = "flex";
      tab.previewMode = true;
      if (tab.previewBtn) {
        tab.previewBtn.textContent = "Edit";
        tab.previewBtn.classList.add("active");
      }
      if (tab.saveBtn) tab.saveBtn.style.display = "none";
      renderMarkdownPreview(tab);
    } else {
      // 预览 → 编辑
      previewContainer.style.display = "none";
      editorContainer.style.display = "";
      tab.previewMode = false;
      if (tab.previewBtn) {
        tab.previewBtn.textContent = "Preview";
        tab.previewBtn.classList.remove("active");
      }
      if (tab.saveBtn) tab.saveBtn.style.display = "";
      if (tab.editorView) {
        requestAnimationFrame(() => tab.editorView.focus());
      }
    }
  }

  /**
   * 渲染 Markdown 预览内容
   */
  function renderMarkdownPreview(tab) {
    if (!tab || !tab.previewContainer) return;

    initMarked();
    if (!window.marked) {
      tab.previewContainer.innerHTML =
        '<div class="preview-error">marked.js 未加载</div>';
      return;
    }

    // 获取编辑器当前内容
    let mdText = "";
    if (tab.editorView) {
      mdText = tab.editorView.state.doc.toString();
    }

    const html = marked.parse(mdText);
    tab.previewContainer.innerHTML =
      '<div class="markdown-body">' + html + "</div>";

    // 加载相对路径图片
    loadRelativeImages(tab);

    // 渲染 Mermaid 图表
    renderMermaidDiagrams(tab.previewContainer);
  }

  /**
   * 解析相对路径为基于 .md 文件目录的完整路径
   */
  function resolveRelativePath(baseDir, relativeSrc) {
    let fullPath;
    if (relativeSrc.startsWith("/")) {
      fullPath = relativeSrc;
    } else {
      fullPath = baseDir ? baseDir + "/" + relativeSrc : relativeSrc;
    }
    // 路径规范化（处理 ../ 和 ./）
    const parts = fullPath.split("/");
    const resolved = [];
    for (const part of parts) {
      if (part === "." || part === "") continue;
      if (part === "..") {
        resolved.pop();
      } else {
        resolved.push(part);
      }
    }
    return resolved.join("/");
  }

  /**
   * 加载相对路径图片（通过 WebSocket file_read）
   * 同时处理两种来源：
   * 1. Markdown ![]() 语法 → 自定义 renderer 输出的 data-relative-src 占位符
   * 2. HTML <img src="..."> 标签 → marked 直接透传，src 为相对路径
   */
  function loadRelativeImages(tab) {
    if (!tab || !tab.previewContainer) return;

    // 获取 .md 文件所在目录
    const filePath = tab.filePath || "";
    const lastSlash = filePath.lastIndexOf("/");
    const baseDir = lastSlash >= 0 ? filePath.substring(0, lastSlash) : "";

    // 收集所有需要异步加载的图片
    const toLoad = []; // { img, fullPath }

    // 1) 由自定义 renderer 生成的占位符
    tab.previewContainer.querySelectorAll("img[data-relative-src]").forEach((img) => {
      const rel = img.getAttribute("data-relative-src");
      if (rel) toLoad.push({ img, fullPath: resolveRelativePath(baseDir, rel) });
    });

    // 2) HTML <img src="..."> 透传标签中的相对路径
    //    排除已有 data-relative-src 的（上面已处理）、绝对 URL、data URL
    tab.previewContainer.querySelectorAll("img[src]").forEach((img) => {
      if (img.hasAttribute("data-relative-src")) return;
      const src = img.getAttribute("src");
      if (!src) return;
      if (/^https?:\/\//i.test(src) || /^data:/i.test(src)) return;
      // 相对路径，需要异步加载
      img.classList.add("md-image-loading");
      img.removeAttribute("src");
      toLoad.push({ img, fullPath: resolveRelativePath(baseDir, src) });
    });

    if (toLoad.length === 0) return;

    toLoad.forEach(({ img, fullPath }) => {
      if (!TF._pendingImageLoads.has(fullPath)) {
        TF._pendingImageLoads.set(fullPath, new Set());
      }
      TF._pendingImageLoads.get(fullPath).add(img);

      // 发送文件读取请求（同一路径只发一次）
      if (TF._pendingImageLoads.get(fullPath).size === 1 && tab.project && tab.workspace) {
        TF.sendFileRead(tab.project, tab.workspace, fullPath);
      }
    });
  }

  /**
   * 处理图片读取结果
   * 返回 true 表示已处理（是图片请求），false 表示不是图片请求
   */
  function handleImageReadResult(path, contentBytes) {
    if (!TF._pendingImageLoads.has(path)) return false;

    const imgSet = TF._pendingImageLoads.get(path);
    TF._pendingImageLoads.delete(path);

    if (!contentBytes || imgSet.size === 0) return true;

    // 检测 MIME 类型
    const bytes = new Uint8Array(contentBytes);
    const mime = detectImageMime(bytes);
    if (!mime) {
      // 不是图片，标记错误
      imgSet.forEach((img) => {
        img.classList.remove("md-image-loading");
        img.classList.add("md-image-error");
        img.alt = "[无法加载: " + path + "]";
      });
      return true;
    }

    // 转 base64 data URL
    let binary = "";
    for (let i = 0; i < bytes.length; i++) {
      binary += String.fromCharCode(bytes[i]);
    }
    const base64 = btoa(binary);
    const dataUrl = "data:" + mime + ";base64," + base64;

    imgSet.forEach((img) => {
      img.src = dataUrl;
      img.classList.remove("md-image-loading");
    });

    return true;
  }

  /**
   * 检测图片 MIME 类型（通过 magic bytes）
   */
  function detectImageMime(bytes) {
    if (bytes.length < 4) return null;
    // PNG
    if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) {
      return "image/png";
    }
    // JPEG
    if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
      return "image/jpeg";
    }
    // GIF
    if (bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) {
      return "image/gif";
    }
    // WebP
    if (bytes.length >= 12 && bytes[0] === 0x52 && bytes[1] === 0x49 &&
        bytes[2] === 0x46 && bytes[3] === 0x46 &&
        bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) {
      return "image/webp";
    }
    // SVG (text-based, check for <?xml or <svg)
    const head = new TextDecoder().decode(bytes.slice(0, 256));
    if (head.includes("<svg") || (head.includes("<?xml") && head.includes("svg"))) {
      return "image/svg+xml";
    }
    return null;
  }

  /**
   * 渲染 Mermaid 图表
   */
  function renderMermaidDiagrams(container) {
    if (!window.mermaid) return;
    initMermaid();

    const mermaidDivs = container.querySelectorAll(".mermaid");
    if (mermaidDivs.length === 0) return;

    mermaidDivs.forEach((div) => {
      const code = div.textContent;
      mermaidCounter++;
      const id = "mermaid-" + mermaidCounter;
      try {
        mermaid.render(id, code).then(({ svg }) => {
          div.innerHTML = svg;
        }).catch((err) => {
          div.innerHTML =
            '<div class="mermaid-error">Mermaid 渲染失败: ' +
            (err.message || err) +
            "</div>";
        });
      } catch (err) {
        div.innerHTML =
          '<div class="mermaid-error">Mermaid 渲染失败: ' +
          (err.message || err) +
          "</div>";
      }
    });
  }

  TF.isMarkdownFile = isMarkdownFile;
  TF.toggleMarkdownPreview = toggleMarkdownPreview;
  TF.renderMarkdownPreview = renderMarkdownPreview;
  TF.handleImageReadResult = handleImageReadResult;
})();
