/**
 * Objective-C 语法增强（MarkMark 自有，非 Prism 上游文件）
 *
 * 为什么要这一层：
 * Prism 1.29 的 `objectivec` 语法只覆盖 `@interface` / `#import` 这类指令、字符串、数字和注释。
 * 一段纯粹的消息发送代码——例如
 *     NSString *optionQuoteType = [[Manager sharedInstance] pnlType];
 * ——拿不到任何有颜色的 token，只会剩下 `operator` 和 `punctuation`；而主题把这两个 token
 * 画成正文色（见 ThemeColors.codeHighlightCSS），于是整块代码看起来像完全没高亮。
 *
 * 这里在语法加载完成后补一层 token，让类名、函数调用、选择器片段和布尔值有颜色：
 *   boolean    YES / NO / nil / NULL …
 *   function   函数调用 `NSLog(`、选择器片段 `requestWithQuoteType:`
 *   class-name `NSString`、`TBTradePositionSettingManager` 这类首字母大写的类型名
 *
 * 实现上刻意不改 `prism-objectivec.min.js`（保持与 upstream 1.29.0 逐字节一致，便于日后整体升级），
 * 而是用 `before-tokenize` 钩子在语法就绪后插入 token。用钩子而不是加载时立即执行，是因为
 * 组件由 autoloader 按需异步加载，本文件执行的那一刻 `Prism.languages.objectivec` 通常还不存在。
 */
(function () {
    if (typeof Prism === 'undefined' || !Prism.languages || !Prism.hooks) {
        return;
    }

    // 标记写进 grammar 对象自身，重复调用不会叠加 token（同一对象会被 `objc` 别名共用）。
    // 必须是**不可枚举**属性：Prism 的 tokenize 用 `for (var key in grammar)` 遍历规则，
    // 一个值为 `true` 的可枚举标记会被当成语法规则去调 `pattern.exec()` 而直接抛错。
    var ENRICHED = '__markmarkObjcEnriched';

    // 键的顺序即优先级：同一位置上靠前的 token 获胜。
    // 因此 boolean（YES）必须早于 class-name，function（NSLog( / foo:）也必须早于 class-name。
    var extras = {
        boolean: /\b(?:YES|NO|TRUE|FALSE|true|false|nil|Nil|NULL)\b/,
        'function': [
            {
                // 函数调用：NSLog( … )、dispatch_async( … )、objc_msgSend( … )
                pattern: /\b[A-Za-z_]\w*(?=\s*\()/,
                greedy: true
            },
            {
                // 消息发送的选择器片段：`requestWithQuoteType:quoteType`
                // 冒号必须紧跟标识符、且只认单个冒号：
                //   - 允许空白会让 `@interface Person : NSObject` 里的 `Person` 被当成选择器
                //   - 排除 `::` 是为了避开 C++
                pattern: /\b[A-Za-z_]\w*(?=:(?!:))/,
                greedy: true
            }
        ],
        'class-name': /\b[A-Z][A-Za-z0-9_]*\b/
    };

    // 返回增强后的 grammar；已经增强过则返回 null。
    function enrich() {
        var grammar = Prism.languages.objectivec;
        if (!grammar || grammar[ENRICHED]) {
            return null;
        }
        // 插到 operator 之前：保持注释/字符串/预处理指令等既有 token 的优先级不变，
        // 只在这之后、标点之前抢标识符。
        // insertBefore 会新建一个 grammar 对象并替换掉旧引用，所以标记要打在**新**对象上。
        var enriched = Prism.languages.insertBefore('objectivec', 'operator', extras);
        Object.defineProperty(enriched, ENRICHED, { value: true, enumerable: false });
        return enriched;
    }

    Prism.hooks.add('before-tokenize', function (environment) {
        var language = environment && environment.language;
        if (language !== 'objectivec' && language !== 'objc') {
            return;
        }
        var enriched = enrich();
        // 关键：`highlightElement` 在跑钩子**之前**就把 grammar 抓进了 env，
        // insertBefore 换掉的是 `Prism.languages.objectivec` 里的引用，而 env 还指着旧对象。
        // 不把新对象塞回 env，当前这块代码仍然会用旧语法渲染（表现为「第一个代码块没变化」）。
        if (enriched) {
            environment.grammar = enriched;
        }
    });
})();
