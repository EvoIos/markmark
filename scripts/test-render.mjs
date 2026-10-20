#!/usr/bin/env node
// 渲染结果回归：在 node 里加载随包的 Prism 组件，断言代码块真实产出的 token 类别。
//
// `swift test` 测的是「组件在不在、顺序对不对」，测不到「这段代码高亮出来是什么样」。
// 2.0.21（php 钩子崩溃）和 2.0.22（Objective-C 只有两类 token，看着是灰的）
// 都是前者全绿、后者全错，所以这两件事分开测。
//
// 用法: node scripts/test-render.mjs
// 退出码: 0 全部通过 / 1 有失败

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const JS_DIR = join(ROOT, "Sources/MarkMark/Resources/js");

// 加载顺序照 app 运行时：core 里已含 markup / css / clike / javascript，
// 其余组件按各自 extends 的依赖顺序补齐。
const CORE = ["prism-core.min.js"];

function loadPrism(files) {
  const ctx = { console };
  ctx.window = ctx;
  ctx.self = ctx;
  vm.createContext(ctx);
  for (const file of [...CORE, ...files]) {
    const path = join(JS_DIR, file);
    let source;
    try {
      source = readFileSync(path, "utf8");
    } catch {
      throw new Error(`缺少组件: ${file}`);
    }
    vm.runInContext(source, ctx, { filename: file });
  }
  return ctx;
}

function highlight(ctx, code, language) {
  return vm.runInContext(
    `Prism.highlight(${JSON.stringify(code)}, Prism.languages[${JSON.stringify(language)}], ${JSON.stringify(language)})`,
    ctx,
  );
}

function tokenTypes(html) {
  const found = new Set();
  for (const match of html.matchAll(/class="token ([^"]*)"/g)) {
    for (const part of match[1].split(/\s+/)) {
      if (part) found.add(part);
    }
  }
  return found;
}

// 每条用例独立加载，避免组件之间互相污染。
const cases = [
  {
    name: "Objective-C 产出类型名、调用、布尔三类 token",
    files: ["prism-c.min.js", "prism-objectivec.min.js", "prism-objectivec-extra.js"],
    language: "objectivec",
    code: 'NSString *a = [[Manager sharedInstance] pnlType];\nNSLog(@"%@", a);\nBOOL ok = YES;',
    // 2.0.22 之前只有 operator 和 punctuation，整块看着和没高亮一样
    expectTypes: ["class-name", "function", "boolean"],
    rejectTypes: [],
  },
  {
    name: "php 在 markup-templating 之后加载不抛错",
    files: ["prism-markup-templating.min.js", "prism-php.min.js"],
    language: "php",
    code: "<?php echo $a; ?>",
    expectTypes: ["keyword"],
    rejectTypes: [],
  },
  {
    name: "php 缺 markup-templating 时抛错（依赖不是可选的）",
    files: ["prism-php.min.js"],
    language: "php",
    code: "<?php echo $a; ?>",
    // 2.0.21 的现场：钩子里的 buildPlaceholders 在 undefined 上调用，
    // 之后每一次高亮都连带失败。这条用例锁住"依赖是真的必需"。
    expectThrow: /buildPlaceholders/,
  },
  {
    name: "swift 基础语法产出 token",
    files: ["prism-swift.min.js"],
    language: "swift",
    code: 'let x = try? URL(string: "https://example.com") // note',
    expectTypes: ["keyword", "string", "comment"],
    rejectTypes: [],
  },
  {
    name: "diff 产出标记 token",
    files: ["prism-diff.min.js"],
    language: "diff",
    code: "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new",
    expectTypes: ["inserted", "deleted"],
    rejectTypes: [],
  },
];

let failures = 0;

for (const testCase of cases) {
  let detail;
  try {
    const ctx = loadPrism(testCase.files);

    if (testCase.expectThrow) {
      try {
        highlight(ctx, testCase.code, testCase.language);
      } catch (error) {
        if (!testCase.expectThrow.test(error.message)) {
          throw new Error(`抛错信息不符，期望匹配 ${testCase.expectThrow}，实际: ${error.message}`);
        }
        console.log(`  ✅ ${testCase.name}`);
        continue;
      }
      throw new Error("应当抛错，实际正常返回");
    }

    const types = tokenTypes(highlight(ctx, testCase.code, testCase.language));
    const missing = testCase.expectTypes.filter((type) => !types.has(type));
    const leaked = testCase.rejectTypes.filter((type) => types.has(type));
    if (missing.length > 0) {
      throw new Error(`缺少 token: ${missing.join(", ")}（实际: ${[...types].sort().join(", ") || "无"}）`);
    }
    if (leaked.length > 0) {
      throw new Error(`不应出现 token: ${leaked.join(", ")}`);
    }
    detail = [...types].sort().join(", ");
  } catch (error) {
    console.log(`  ❌ ${testCase.name}`);
    console.log(`       ${error.message}`);
    failures += 1;
    continue;
  }
  console.log(`  ✅ ${testCase.name}  ${detail ? `(${detail})` : ""}`);
}

console.log("");
if (failures > 0) {
  console.log(`RENDER TEST: FAIL (${failures}/${cases.length})`);
  process.exit(1);
}
console.log(`RENDER TEST: PASS (${cases.length} 组)`);
