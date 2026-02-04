/**
 * CodeMirror 6 Bundle 构建脚本
 * 使用 esbuild 打包所有依赖到单个文件
 */

const esbuild = require("esbuild");
const path = require("path");

const outfile = path.resolve(
  __dirname,
  "../app/TidyFlow/Web/vendor/codemirror.bundle.js"
);

esbuild
  .build({
    entryPoints: [path.resolve(__dirname, "src/codemirror-bundle.js")],
    bundle: true,
    minify: true,
    sourcemap: false,
    format: "iife",
    target: ["safari15"],
    outfile: outfile,
  })
  .then(() => {
    console.log(`✓ Bundle 构建成功: ${outfile}`);
  })
  .catch((err) => {
    console.error("构建失败:", err);
    process.exit(1);
  });
