(function() {
  const MR = {
    version: '2.0.0',

    scrollToHeading(id) {
      const el = document.getElementById(id);
      if (el) {
        el.scrollIntoView({ behavior: 'smooth', block: 'start' });
        el.classList.add('outline-highlight');
        setTimeout(() => {
          el.classList.add('fade-out');
          setTimeout(() => {
            el.classList.remove('outline-highlight', 'fade-out');
          }, 300);
        }, 1500);
      }
    },

    scrollToLine(lineNumber) {
      const target = document.querySelector(`[data-line="${lineNumber}"]`);
      if (target) {
        target.scrollIntoView({ behavior: 'smooth', block: 'center' });
        return true;
      }
      let closest = null;
      let minDiff = Infinity;
      document.querySelectorAll('[data-line]').forEach(el => {
        const diff = Math.abs(parseInt(el.dataset.line) - lineNumber);
        if (diff < minDiff) {
          minDiff = diff;
          closest = el;
        }
      });
      if (closest) {
        closest.scrollIntoView({ behavior: 'smooth', block: 'center' });
        return true;
      }
      return false;
    },

    replaceContent(html, diff) {
      const content = document.getElementById('mr-content');
      if (content) {
        content.innerHTML = html;
        MR._searchHighlights = [];
        // diff 标记必须在 Mermaid / KaTeX / Prism 改写 DOM 之前叠加（逐词 diff 依赖原始文本节点）
        MR.applyDiff(diff || null);
        MR.renderMermaid();
        MR.renderPlantUML();
        MR.renderKaTeX();
        MR.renderAdmonitions();
        MR.renderBlockComments();
        MR.addCopyButtons();
        MR._hideBlockAdd();
        if (typeof Prism !== 'undefined') {
          Prism.highlightAll();
        }
      }
    },

    // 块级元素被替换为渲染容器时（Mermaid / KaTeX），沿用原块的源码行号，
    // 否则滚动同步、段落批注插入点会丢失。
    _copyLineAttrs(from, to) {
      if (!from || !to || !from.dataset) return;
      if (from.dataset.line) to.dataset.line = from.dataset.line;
      if (from.dataset.lineEnd) to.dataset.lineEnd = from.dataset.lineEnd;
      ['mr-diff-added', 'mr-diff-modified'].forEach(c => {
        if (from.classList.contains(c)) to.classList.add(c);
      });
    },

    getVisibleHeading() {
      const headings = document.querySelectorAll('h1[id], h2[id], h3[id], h4[id], h5[id], h6[id]');
      let visible = null;
      const scrollTop = window.scrollY || document.documentElement.scrollTop;
      const threshold = 100;
      for (let i = headings.length - 1; i >= 0; i--) {
        if (headings[i].getBoundingClientRect().top <= threshold) {
          visible = {
            id: headings[i].id,
            level: parseInt(headings[i].tagName.charAt(1)),
            title: headings[i].textContent.trim(),
            lineNumber: parseInt(headings[i].dataset.line || '0')
          };
          break;
        }
      }
      return visible;
    },

    getTopVisibleLine() {
      const elements = document.querySelectorAll('[data-line]');
      const threshold = 120;
      let best = null;
      let minDiff = Infinity;
      for (let i = elements.length - 1; i >= 0; i--) {
        const rect = elements[i].getBoundingClientRect();
        const diff = threshold - rect.top;
        if (diff >= 0 && diff < minDiff) {
          minDiff = diff;
          best = elements[i];
        }
      }
      if (best) {
        return parseInt(best.dataset.line) || 1;
      }
      return 1;
    },

    getScrollPosition() {
      return {
        x: window.scrollX || document.documentElement.scrollLeft,
        y: window.scrollY || document.documentElement.scrollTop
      };
    },

    // 解析承载配置的 <script> 标签。
    // app / QuickLook 通过 src 引用脚本（src*="markdown-reader.js"）；
    // HTML 导出把脚本内联（无 src），改用 data-mr-config 标记定位。
    _configEl() {
      return document.querySelector('script[data-mr-config]')
        || document.querySelector('script[src*="markdown-reader.js"]');
    },

    // 只读环境（QuickLook 预览、导出的静态 HTML）不应出现无效的标注编辑入口。
    _isReadonly() {
      const el = this._configEl();
      return !!el && (el.dataset.isQuicklook === 'true' || el.dataset.readonly === 'true');
    },

    _resolveThemeColors() {
      const scriptTag = this._configEl();
      const isDark = scriptTag ? scriptTag.dataset.isDark === 'true' : true;

      // Mermaid strips var() refs (sanitizeDirective) and khroma needs hex for adjust/darken/invert.
      const style = getComputedStyle(document.documentElement);
      const resolve = (v) => {
        if (!v || !v.startsWith('var(')) return v;
        const inner = v.slice(4, v.lastIndexOf(')')).trim();
        const name = inner.includes(',') ? inner.slice(0, inner.indexOf(',')).trim() : inner;
        let resolved = style.getPropertyValue(name).trim();
        if (resolved.startsWith('var(')) resolved = resolve(resolved);
        return resolved || v;
      };

      // Canvas fillStyle converts CSS colors to #rrggbb but drops the alpha channel.
      // For rgba() values (common in theme borders/muted text), blend with the
      // surface background first so the result matches what users see on screen.
      const toHex = (cssColor) => {
        if (!cssColor || cssColor.startsWith('#')) return cssColor;
        const ctx = document.createElement('canvas').getContext('2d');
        ctx.fillStyle = cssColor;
        const result = ctx.fillStyle;
        // If rgba was converted to #rrggbb, alpha was lost — pre-blend it
        if (result.startsWith('#') && cssColor.includes('rgba')) {
          const match = cssColor.match(/rgba?\(\s*(\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\)/);
          if (match) {
            const r = parseInt(match[1]), g = parseInt(match[2]), b = parseInt(match[3]), a = parseFloat(match[4]);
            const surface = isDark ? [24, 24, 26] : [255, 255, 255];
            const blended = [
              Math.round(surface[0] * (1 - a) + r * a),
              Math.round(surface[1] * (1 - a) + g * a),
              Math.round(surface[2] * (1 - a) + b * a)
            ];
            return '#' + blended.map(c => c.toString(16).padStart(2, '0')).join('');
          }
        }
        return result;
      };

      return {
        isDark,
        themeVariables: {
          primaryColor: toHex(resolve('var(--accent)')),
          primaryTextColor: toHex(resolve('var(--ink)')),
          primaryBorderColor: toHex(resolve('var(--border)')),
          lineColor: toHex(resolve('var(--fg-muted)')),
          secondaryColor: toHex(resolve('var(--bg-elevated)')),
          tertiaryColor: toHex(resolve('var(--bg-subtle)'))
        }
      };
    },

    _showMermaidError(container, msg) {
      container.innerHTML = '';
      const errBox = document.createElement('div');
      errBox.className = 'mermaid-error';
      errBox.innerHTML = '<strong>Mermaid</strong> — ' + msg;
      container.appendChild(errBox);
    },

    async _encodePlantUML(text) {
      const encoder = new TextEncoder();
      const data = encoder.encode(text);

      const cs = new CompressionStream('deflate-raw');
      const writer = cs.writable.getWriter();
      writer.write(data);
      writer.close();

      const reader = cs.readable.getReader();
      const chunks = [];
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        chunks.push(value);
      }
      const compressed = new Uint8Array(chunks.reduce((acc, c) => acc + c.length, 0));
      let offset = 0;
      for (const chunk of chunks) {
        compressed.set(chunk, offset);
        offset += chunk.length;
      }

      const map = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_';
      let result = '';
      for (let i = 0; i < compressed.length; i += 3) {
        const b1 = compressed[i];
        const b2 = i + 1 < compressed.length ? compressed[i + 1] : 0;
        const b3 = i + 2 < compressed.length ? compressed[i + 2] : 0;
        result += map[b1 >> 2];
        result += map[((b1 & 0x3) << 4) | (b2 >> 4)];
        result += map[((b2 & 0xF) << 2) | (b3 >> 6)];
        result += map[b3 & 0x3F];
      }
      return result;
    },

    _showPlantUMLError(container, msg) {
      container.innerHTML = '';
      const errBox = document.createElement('div');
      errBox.className = 'plantuml-error';
      errBox.innerHTML = '<strong>PlantUML</strong> — ' + msg;
      container.appendChild(errBox);
    },

    renderMermaid() {
      const mermaidBlocks = document.querySelectorAll('code.language-mermaid, pre code.language-mermaid');
      if (mermaidBlocks.length === 0) return;
      if (typeof mermaid === 'undefined') return;

      const { isDark, themeVariables } = MR._resolveThemeColors();

      mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'loose',
        theme: isDark ? 'dark' : 'default',
        themeVariables
      });

      let idx = 0;
      mermaidBlocks.forEach(block => {
        const pre = block.parentElement;
        if (!pre || pre.tagName !== 'PRE') return;
        const source = block.textContent;
        const container = document.createElement('div');
        container.className = 'mermaid-container';
        container.dataset.mermaidSource = source;
        const id = 'mermaid-' + (++idx) + '-' + Math.random().toString(36).slice(2);
        mermaid.render(id, source).then(({ svg, bindFunctions }) => {
          container.innerHTML = svg;
          if (bindFunctions) bindFunctions(container);
        }).catch(err => {
          console.error('[MarkdownReader] mermaid.render error:', err);
          const detail = (err && err.message) ? String(err.message).substring(0, 200) : String(err).substring(0, 200);
          MR._showMermaidError(container, '渲染失败：' + detail);
        });
        MR._copyLineAttrs(pre, container);
        pre.replaceWith(container);
      });
    },

    rerenderMermaid() {
      const containers = document.querySelectorAll('.mermaid-container');
      if (containers.length === 0) return;
      if (typeof mermaid === 'undefined') return;

      const { isDark, themeVariables } = MR._resolveThemeColors();

      mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'loose',
        theme: isDark ? 'dark' : 'default',
        themeVariables
      });

      containers.forEach((container, idx) => {
        const source = container.dataset.mermaidSource;
        if (!source) return;
        const id = 'mermaid-re-' + idx + '-' + Math.random().toString(36).slice(2);
        container.innerHTML = '';
        mermaid.render(id, source).then(({ svg, bindFunctions }) => {
          container.innerHTML = svg;
          if (bindFunctions) bindFunctions(container);
        }).catch(err => {
          console.error('[MarkdownReader] mermaid rerender error:', err);
          const detail = (err && err.message) ? String(err.message).substring(0, 200) : String(err).substring(0, 200);
          MR._showMermaidError(container, '渲染失败：' + detail);
        });
      });
    },

    async _fetchPlantUMLSVG(source, serverUrl) {
      const encoded = await MR._encodePlantUML(source);
      const svgUrl = `${serverUrl}/svg/~1${encoded}`;
      const response = await fetch(svgUrl);
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const text = await response.text();
      if (!text.trim().startsWith('<svg')) {
        throw new Error('服务器返回了无效的 SVG 内容');
      }
      return text;
    },

    _applyPlantUMLSVG(container, svgText) {
      container.innerHTML = svgText;
      const svgEl = container.querySelector('svg');
      if (svgEl) {
        svgEl.removeAttribute('width');
        svgEl.removeAttribute('height');
        svgEl.style.maxWidth = '100%';
        svgEl.style.height = 'auto';
      }
    },

    async renderPlantUML() {
      const plantumlBlocks = document.querySelectorAll('code.language-plantuml, pre code.language-plantuml, code.language-puml, pre code.language-puml');
      if (plantumlBlocks.length === 0) return;

      const serverUrl = 'https://www.plantuml.com/plantuml';

      const tasks = Array.from(plantumlBlocks).map(block => {
        const pre = block.parentElement;
        if (!pre || pre.tagName !== 'PRE') return Promise.resolve();

        const source = block.textContent;
        const container = document.createElement('div');
        container.className = 'plantuml-container';
        container.dataset.plantumlSource = source;

        container.innerHTML = '<div class="plantuml-loading">PlantUML...</div>';
        pre.replaceWith(container);

        return MR._fetchPlantUMLSVG(source, serverUrl)
          .then(svg => { MR._applyPlantUMLSVG(container, svg); })
          .catch(err => {
            console.error('[MarkdownReader] PlantUML render error:', err);
            MR._showPlantUMLError(container, '渲染失败：' + (err.message || String(err)).substring(0, 200));
          });
      });

      await Promise.all(tasks);
    },

    async rerenderPlantUML() {
      const containers = document.querySelectorAll('.plantuml-container');
      if (containers.length === 0) return;

      const serverUrl = 'https://www.plantuml.com/plantuml';

      const tasks = Array.from(containers).map(container => {
        const source = container.dataset.plantumlSource;
        if (!source) return Promise.resolve();
        container.innerHTML = '<div class="plantuml-loading">PlantUML...</div>';

        return MR._fetchPlantUMLSVG(source, serverUrl)
          .then(svg => { MR._applyPlantUMLSVG(container, svg); })
          .catch(err => {
            console.error('[MarkdownReader] PlantUML rerender error:', err);
            MR._showPlantUMLError(container, '渲染失败：' + (err.message || String(err)).substring(0, 200));
          });
      });

      await Promise.all(tasks);
    },

    renderKaTeX() {
      const mathElements = document.querySelectorAll('code.language-math, code.language-latex, code.language-katex');
      if (mathElements.length === 0) return;
      if (typeof katex === 'undefined') return;

      mathElements.forEach(block => {
        const pre = block.parentElement;
        const isInline = !pre || pre.tagName !== 'PRE';
        const mathContent = block.textContent;

        if (isInline) {
          const span = document.createElement('span');
          span.className = 'katex-inline';
          try {
            katex.render(mathContent, span, {
              displayMode: false,
              throwOnError: false,
              output: 'html'
            });
          } catch (e) {
            span.textContent = mathContent;
          }
          block.replaceWith(span);
        } else {
          const container = document.createElement('div');
          container.className = 'katex-display';
          try {
            katex.render(mathContent, container, {
              displayMode: true,
              throwOnError: false,
              output: 'html'
            });
          } catch (e) {
            container.textContent = mathContent;
          }
          MR._copyLineAttrs(pre, container);
          pre.replaceWith(container);
        }
      });
    },

    renderAdmonitions() {
      const blockquotes = document.querySelectorAll('blockquote');
      const types = {
        'note': { icon: 'ℹ', label: 'Note' },
        'tip': { icon: '💡', label: 'Tip' },
        'warning': { icon: '⚠', label: 'Warning' },
        'caution': { icon: '🔥', label: 'Caution' },
        'important': { icon: '❗', label: 'Important' }
      };
      blockquotes.forEach(bq => {
        const firstP = bq.querySelector('p');
        if (!firstP) return;
        const text = firstP.textContent.trim();
        for (const [type, config] of Object.entries(types)) {
          const prefix = '[' + type.charAt(0).toUpperCase() + type.slice(1) + ']';
          if (text.startsWith(prefix)) {
            bq.classList.add('admonition', 'admonition-' + type);
            const titleSpan = document.createElement('span');
            titleSpan.className = 'admonition-title';
            titleSpan.textContent = config.label;
            const rest = text.slice(prefix.length).trim();
            if (rest) {
              firstP.textContent = rest;
            } else {
              firstP.remove();
            }
            bq.insertBefore(titleSpan, bq.firstChild);
            break;
          }
        }
      });
    },

    addCopyButtons() {
      const preBlocks = document.querySelectorAll('pre');
      preBlocks.forEach(pre => {
        if (pre.querySelector('.mr-copy-btn')) return;
        pre.style.position = 'relative';

        const btn = document.createElement('button');
        btn.className = 'mr-copy-btn';
        btn.type = 'button';
        btn.title = 'Copy';
        btn.innerHTML = '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="5" width="9" height="9" rx="1.5"/><path d="M3 11V3a1.5 1.5 0 0 1 1.5-1.5H11"/></svg>';

        btn.addEventListener('click', function() {
          const code = pre.querySelector('code');
          const text = code ? code.textContent : pre.textContent;
          navigator.clipboard.writeText(text).then(() => {
            btn.classList.add('mr-copy-btn-copied');
            btn.innerHTML = '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="3.5 8.5 6.5 11.5 12.5 5.5"/></svg>';
            setTimeout(() => {
              btn.classList.remove('mr-copy-btn-copied');
              btn.innerHTML = '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="5" width="9" height="9" rx="1.5"/><path d="M3 11V3a1.5 1.5 0 0 1 1.5-1.5H11"/></svg>';
            }, 2000);
          }).catch(() => {
            const textarea = document.createElement('textarea');
            textarea.value = text;
            textarea.style.position = 'fixed';
            textarea.style.opacity = '0';
            document.body.appendChild(textarea);
            textarea.select();
            document.execCommand('copy');
            document.body.removeChild(textarea);
            btn.classList.add('mr-copy-btn-copied');
            btn.innerHTML = '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="3.5 8.5 6.5 11.5 12.5 5.5"/></svg>';
            setTimeout(() => {
              btn.classList.remove('mr-copy-btn-copied');
              btn.innerHTML = '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="5" width="9" height="9" rx="1.5"/><path d="M3 11V3a1.5 1.5 0 0 1 1.5-1.5H11"/></svg>';
            }, 2000);
          });
        });

        pre.appendChild(btn);
      });
    },

    _searchHighlights: [],

    highlightSearch(query, caseSensitive, wholeWord, currentIndex) {
      MR.clearSearchHighlight();
      if (!query) return 0;

      const content = document.getElementById('mr-content');
      if (!content) return 0;

      const flags = caseSensitive ? 'g' : 'gi';
      let pattern = query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      if (wholeWord) pattern = '\\b' + pattern + '\\b';

      let regex;
      try {
        regex = new RegExp(pattern, flags);
      } catch (e) {
        return 0;
      }

      const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT, null);
      const textNodes = [];
      while (walker.nextNode()) {
        textNodes.push(walker.currentNode);
      }

      const allMatches = [];

      textNodes.forEach(node => {
        const text = node.textContent;
        let match;
        while ((match = regex.exec(text)) !== null) {
          allMatches.push({
            node: node,
            index: match.index,
            length: match[0].length
          });
        }
      });

      // Sort by document position in REVERSE order for safe insertion.
      // Processing from end to start prevents surroundContents from
      // splitting text nodes and invalidating later match offsets.
      const sortedAllMatches = allMatches.slice().sort((a, b) => {
        const cmp = a.node.compareDocumentPosition(b.node);
        if (cmp & Node.DOCUMENT_POSITION_FOLLOWING) return 1;  // b comes first → process b before a
        if (cmp & Node.DOCUMENT_POSITION_PRECEDING) return -1; // a comes first → process a before b
        return b.index - a.index; // same node: higher index first
      });

      // Collect mark elements in document order for indexing
      const markElements = [];

      // Use Range API to wrap matches in <mark> elements
      for (const m of sortedAllMatches) {
        const range = document.createRange();
        try {
          range.setStart(m.node, m.index);
          range.setEnd(m.node, m.index + m.length);
        } catch (e) {
          continue;
        }

        const mark = document.createElement('mark');
        mark.className = 'mr-search-highlight';

        try {
          range.surroundContents(mark);
          markElements.unshift(mark); // prepend to maintain document order
        } catch (e) {
          // surroundContents fails when range crosses element boundaries — skip
          continue;
        }
      }

      // Assign sequential indices in document order
      markElements.forEach((mark, i) => {
        mark.dataset.searchIndex = i;
      });
      MR._searchHighlights = markElements;

      const matchCount = markElements.length;

      // Highlight current match
      if (currentIndex >= 0 && currentIndex < matchCount) {
        const currentMark = content.querySelector(`mark[data-search-index="${currentIndex}"]`);
        if (currentMark) {
          currentMark.classList.add('mr-search-current');
          currentMark.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
      }

      return matchCount;
    },

    setSearchCurrent(currentIndex) {
      const content = document.getElementById('mr-content');
      if (!content) return;
      const prev = content.querySelector('.mr-search-current');
      if (prev) prev.classList.remove('mr-search-current');
      if (currentIndex >= 0) {
        const mark = content.querySelector(`mark[data-search-index="${currentIndex}"]`);
        if (mark) {
          mark.classList.add('mr-search-current');
          mark.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
      }
    },

    clearSearchHighlight() {
      for (const mark of MR._searchHighlights) {
        const parent = mark.parentNode;
        if (parent) {
          while (mark.firstChild) {
            parent.insertBefore(mark.firstChild, mark);
          }
          parent.removeChild(mark);
          parent.normalize();
        }
      }
      MR._searchHighlights = [];
    },

    // ===== CriticMarkup 选词标注 =====

    criticLabels: {
      delete: 'Delete', highlight: 'Highlight', comment: 'Comment', replace: 'Replace',
      confirm: 'Apply', cancel: 'Cancel', edit: 'Edit',
      commentHint: 'Add a comment…', replaceHint: 'Replace with…',
      notFound: 'Could not locate the selection in the source'
    },

    // 定位失败时的轻提示（避免「静默无反应」）
    flashCriticError(msg) {
      const text = msg || (MR.criticLabels && MR.criticLabels.notFound) || 'Could not locate the selection';
      let el = document.getElementById('mr-critic-toast');
      if (!el) {
        el = document.createElement('div');
        el.id = 'mr-critic-toast';
        document.body.appendChild(el);
      }
      el.textContent = text;
      el.classList.add('visible');
      clearTimeout(MR._criticToastTimer);
      MR._criticToastTimer = setTimeout(function() { el.classList.remove('visible'); }, 2200);
    },

    setCriticLabels(labels) {
      if (labels && typeof labels === 'object') {
        MR.criticLabels = Object.assign({}, MR.criticLabels, labels);
      }
    },

    // 用 CSS Custom Highlight API 给「正在标注」的选区上一层持久高亮。
    // 仅在进入评论/替换输入态（原生选区即将因聚焦输入框而消失）时设置；
    // 普通选词阶段原生选区本身可见，叠加高亮反而会触发 WebKit 的残留重绘 bug。
    _setPendingHighlight(range) {
      try {
        if (!window.CSS || !CSS.highlights || typeof Highlight === 'undefined' || !range) return;
        MR._clearPendingHighlight();
        const cloned = range.cloneRange();
        MR._pendingHighlightRange = cloned;
        CSS.highlights.set('critic-pending', new Highlight(cloned));
      } catch (e) { /* no-op */ }
    },

    _clearPendingHighlight() {
      try {
        if (window.CSS && CSS.highlights) {
          // WebKit 偶发 bug：直接从注册表 delete 后，选区首尾字符的高亮不重绘
          // （切换窗口焦点强制全量重绘才消失）。先 clear() 范围再 delete，
          // 并轻触一个 paint-only 属性强制该块重绘。
          const hl = CSS.highlights.get('critic-pending');
          if (hl && typeof hl.clear === 'function') hl.clear();
          CSS.highlights.delete('critic-pending');
        }
        const r = MR._pendingHighlightRange;
        MR._pendingHighlightRange = null;
        if (r) {
          let el = r.commonAncestorContainer;
          if (el && el.nodeType === 3) el = el.parentElement;
          if (el && el.style) {
            el.style.webkitTextFillColor = 'currentcolor';
            requestAnimationFrame(() => { el.style.webkitTextFillColor = ''; });
          }
        }
      } catch (e) { /* no-op */ }
    },

    // 评论草稿：按「位置（行号 + 选中文本）」暂存未提交的评论，重新对同一处选词写评论时自动恢复，
    // 防止误触 Dismiss 丢失刚开始写的内容（issue #7，对应 issue 中的方案 3.3）。
    _criticDraftKey(p) {
      if (!p) return null;
      return String(p.line || 0) + '' + (p.text || '');
    },

    // 把当前评论输入框的内容存为草稿（仅在输入态、且内容非空时）。
    _saveCriticDraft() {
      const bar = document.getElementById('mr-critic-toolbar');
      if (!bar || !bar.classList.contains('critic-input-mode')) return;
      const field = bar.querySelector('.critic-field');
      const key = MR._criticInputDraftKey;
      if (field && key && field.value.trim()) {
        MR._criticDrafts = MR._criticDrafts || {};
        MR._criticDrafts[key] = field.value;
      }
    },

    // 折叠评论中的连续空行：连续 2+ 换行 → 单个换行，并去掉首尾空白行（issue #6）
    _collapseBlankLines(s) {
      if (typeof s !== 'string') return s;
      return s.replace(/[ \t]*\r?\n(?:[ \t]*\r?\n)+/g, '\n').replace(/^\s+|\s+$/g, '');
    },

    _postCriticAction(op, text, line, payload) {
      try {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.criticAction) {
          window.webkit.messageHandlers.criticAction.postMessage({
            op: op, text: text, line: line, payload: payload || null
          });
        }
      } catch (e) { /* no-op */ }
    },

    _criticLineFor(node) {
      let el = (node && node.nodeType === 3) ? node.parentElement : node;
      while (el && el !== document.body) {
        if (el.dataset && el.dataset.line) {
          return parseInt(el.dataset.line) || 0;
        }
        el = el.parentElement;
      }
      return 0;
    },

    _ensureCriticToolbar() {
      let bar = document.getElementById('mr-critic-toolbar');
      if (bar) return bar;
      bar = document.createElement('div');
      bar.id = 'mr-critic-toolbar';
      document.body.appendChild(bar);
      // 普通模式下防止点击工具条按钮清除选区；输入模式（评论/替换）需允许聚焦输入框
      bar.addEventListener('mousedown', function(e) {
        if (!bar.classList.contains('critic-input-mode')) e.preventDefault();
      });
      return bar;
    },

    _hideCriticToolbar() {
      const bar = document.getElementById('mr-critic-toolbar');
      if (bar) {
        bar.classList.remove('visible');
        // 关键：清掉输入态标记，否则取消评论/替换后 selectionchange 守卫会一直 return，
        // 导致再次选词时工具条不再弹出。
        bar.classList.remove('critic-input-mode');
      }
      MR._criticPending = null;
      MR._clearPendingHighlight();
    },

    _showCriticToolbar(range, text, line) {
      const bar = MR._ensureCriticToolbar();
      MR._criticPending = { text: text, line: line };
      MR._criticAnchorRect = null;
      const L = MR.criticLabels;
      bar.innerHTML = '';

      const mkBtn = (label, handler, primary) => {
        const b = document.createElement('button');
        b.textContent = label;
        if (primary) b.className = 'critic-primary';
        b.addEventListener('click', handler);
        return b;
      };

      bar.appendChild(mkBtn(L.delete, () => MR._commitCritic('delete')));
      bar.appendChild(mkBtn(L.highlight, () => MR._commitCritic('highlight')));
      bar.appendChild(mkBtn(L.comment, () => MR._promptCritic('comment', L.commentHint, true)));
      bar.appendChild(mkBtn(L.replace, () => MR._promptCritic('replace', L.replaceHint, false)));

      bar.classList.add('visible');
      MR._positionCriticToolbar(bar, range.getBoundingClientRect());
    },

    _positionCriticToolbar(bar, rect) {
      const barRect = bar.getBoundingClientRect();
      let top = rect.top - barRect.height - 8;
      if (top < 4) top = rect.bottom + 8;
      let left = rect.left + (rect.width / 2) - (barRect.width / 2);
      left = Math.max(4, Math.min(left, window.innerWidth - barRect.width - 4));
      bar.style.top = top + 'px';
      bar.style.left = left + 'px';
    },

    // op: 'comment'(多行 textarea) / 'replace'(单行 input)
    _promptCritic(op, hint, multiline) {
      const bar = document.getElementById('mr-critic-toolbar');
      if (!bar || !MR._criticPending) return;
      const L = MR.criticLabels;
      // 输入框即将抢走焦点、原生选区会消失，此时才给选区上持久高亮
      MR._setPendingHighlight(MR._criticRange);
      bar.classList.add('critic-input-mode');
      bar.innerHTML = '';

      const field = document.createElement(multiline ? 'textarea' : 'input');
      if (!multiline) field.type = 'text';
      field.className = 'critic-field';
      field.placeholder = hint;
      if (multiline) field.rows = 3;

      // 评论草稿：记录本次输入对应的位置 key，并恢复同一处未提交的草稿（issue #7）。
      // 仅评论启用草稿，replace 不需要。
      const isComment = op === 'comment' || op === 'blockComment';
      const draftKey = isComment ? MR._criticDraftKey(MR._criticPending) : null;
      MR._criticInputDraftKey = draftKey;
      MR._criticDrafts = MR._criticDrafts || {};
      if (draftKey && MR._criticDrafts[draftKey] != null) field.value = MR._criticDrafts[draftKey];

      const confirm = document.createElement('button');
      confirm.textContent = L.confirm;
      confirm.className = 'critic-primary';
      const cancel = document.createElement('button');
      cancel.textContent = L.cancel;

      const submit = () => {
        const v = field.value.trim();
        if (isComment && !v) { MR._hideCriticToolbar(); return; }
        // 提交成功 → 清除该位置的草稿
        if (draftKey) delete MR._criticDrafts[draftKey];
        // 评论内的连续空行会破坏 CriticMarkup 行内格式（cmark 会按空行拆段），
        // 提交前自动折叠空行（issue #6）。replace 仅替换正文文本，无需处理。
        const payload = isComment ? MR._collapseBlankLines(field.value) : field.value;
        MR._commitCritic(op, payload);
      };
      // 取消/Esc 关闭前先把内容存为草稿（issue #7，方案 3.3）
      const dismiss = () => { MR._saveCriticDraft(); MR._hideCriticToolbar(); };
      confirm.addEventListener('click', submit);
      cancel.addEventListener('click', dismiss);
      field.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); submit(); }
        else if (e.key === 'Enter' && !multiline) { e.preventDefault(); submit(); }
        else if (e.key === 'Escape') { e.preventDefault(); dismiss(); }
      });

      const row = document.createElement('div');
      row.className = 'critic-input-row';
      row.appendChild(field);
      const btns = document.createElement('div');
      btns.className = 'critic-input-btns';
      btns.appendChild(cancel);
      btns.appendChild(confirm);
      bar.appendChild(row);
      bar.appendChild(btns);
      // 重新定位（输入态尺寸变化）+ 聚焦。段落批注没有选区，用「+」按钮位置定位
      const anchorRect = MR._criticRange ? MR._criticRange.getBoundingClientRect() : MR._criticAnchorRect;
      if (anchorRect) MR._positionCriticToolbar(bar, anchorRect);
      setTimeout(() => field.focus(), 0);
    },

    _commitCritic(op, payload) {
      const p = MR._criticPending;
      if (!p) return;
      MR._postCriticAction(op, p.text, p.line, payload);
      const sel = window.getSelection();
      if (sel) sel.removeAllRanges();
      const bar = document.getElementById('mr-critic-toolbar');
      if (bar) bar.classList.remove('critic-input-mode');
      MR._hideCriticToolbar();
    },

    // ===== 已有评论：查看 / 编辑 / 删除 =====

    _ensureCommentPopover() {
      let pop = document.getElementById('mr-critic-popover');
      if (pop) return pop;
      pop = document.createElement('div');
      pop.id = 'mr-critic-popover';
      document.body.appendChild(pop);
      pop.addEventListener('mousedown', (e) => { e.stopPropagation(); });
      return pop;
    },

    _hideCommentPopover() {
      const pop = document.getElementById('mr-critic-popover');
      if (pop) pop.classList.remove('visible');
      MR._criticPopoverEl = null;
    },

    _positionCriticPopover(pop, rect) {
      const r = pop.getBoundingClientRect();
      let top = rect.bottom + 6;
      if (top + r.height > window.innerHeight - 4) top = Math.max(4, rect.top - r.height - 6);
      let left = rect.left + (rect.width / 2) - (r.width / 2);
      left = Math.max(4, Math.min(left, window.innerWidth - r.width - 4));
      pop.style.top = top + 'px';
      pop.style.left = left + 'px';
    },

    _showCommentPopover(el) {
      const pop = MR._ensureCommentPopover();
      MR._criticPopoverEl = el;
      const L = MR.criticLabels;
      const comment = el.dataset.comment || '';
      const line = MR._criticLineFor(el);
      pop.innerHTML = '';
      pop.classList.remove('critic-input-mode');

      const textBox = document.createElement('div');
      textBox.className = 'critic-popover-text';
      textBox.textContent = comment;
      pop.appendChild(textBox);

      // 只读环境（QuickLook / 导出 HTML）：仅展示评论内容，不提供编辑 / 删除入口
      if (!MR._isReadonly()) {
        const btns = document.createElement('div');
        btns.className = 'critic-input-btns';
        const editBtn = document.createElement('button');
        editBtn.textContent = L.edit;
        editBtn.className = 'critic-primary';
        const delBtn = document.createElement('button');
        delBtn.textContent = L.delete;
        delBtn.className = 'critic-danger';

        editBtn.addEventListener('click', () => MR._editCommentPopover(el, comment, line));
        delBtn.addEventListener('click', () => {
          MR._postCriticAction('deleteComment', comment, line, null);
          MR._hideCommentPopover();
        });

        btns.appendChild(delBtn);
        btns.appendChild(editBtn);
        pop.appendChild(btns);
      }

      pop.classList.add('visible');
      MR._positionCriticPopover(pop, el.getBoundingClientRect());
    },

    _editCommentPopover(el, oldComment, line) {
      const pop = MR._ensureCommentPopover();
      const L = MR.criticLabels;
      pop.innerHTML = '';
      pop.classList.add('critic-input-mode');

      const field = document.createElement('textarea');
      field.className = 'critic-field';
      field.rows = 3;
      field.value = oldComment;

      const btns = document.createElement('div');
      btns.className = 'critic-input-btns';
      const cancel = document.createElement('button');
      cancel.textContent = L.cancel;
      const save = document.createElement('button');
      save.textContent = L.confirm;
      save.className = 'critic-primary';

      const submit = () => {
        const v = field.value.trim();
        if (!v) {
          MR._postCriticAction('deleteComment', oldComment, line, null);
        } else {
          const next = MR._collapseBlankLines(field.value);
          if (next !== oldComment) {
            MR._postCriticAction('editComment', oldComment, line, next);
          }
        }
        MR._hideCommentPopover();
      };
      cancel.addEventListener('click', () => MR._hideCommentPopover());
      save.addEventListener('click', submit);
      field.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); submit(); }
        else if (e.key === 'Escape') { e.preventDefault(); MR._hideCommentPopover(); }
      });

      const row = document.createElement('div');
      row.className = 'critic-input-row';
      row.appendChild(field);
      btns.appendChild(cancel);
      btns.appendChild(save);
      pop.appendChild(row);
      pop.appendChild(btns);
      MR._positionCriticPopover(pop, el.getBoundingClientRect());
      setTimeout(() => { field.focus(); field.select(); }, 0);
    },

    // ===== Diff 模式 =====
    // 载荷由 Swift 端 MarkdownDiff.payloadJSON 生成：按新文档源码行号标出新增 / 修改块，
    // 并给出被删除块的渲染结果与插入位置。修改块的逐词 diff 在这里基于 DOM 文本节点完成，
    // 被删除的文字以不可选中的 span 插回原位，选词批注时不会混进选区。

    _diffTagFor: {
      paragraph: ['P'], heading: ['H1', 'H2', 'H3', 'H4', 'H5', 'H6'], listItem: ['LI'],
      blockQuote: ['BLOCKQUOTE'], code: ['PRE'], table: ['TABLE'], thematicBreak: ['HR']
    },

    _diffFindBlock(line, kind) {
      const content = document.getElementById('mr-content');
      if (!content || !line) return null;
      const els = content.querySelectorAll('[data-line="' + line + '"]');
      const tags = MR._diffTagFor[kind];
      for (const el of els) {
        if (!tags || tags.includes(el.tagName)) return el;
      }
      return els[0] || null;
    },

    // 删除块的锚点：同一行号上优先取列表项或顶层块
    _diffFindAnchor(line) {
      const content = document.getElementById('mr-content');
      if (!content || !line) return null;
      const els = Array.from(content.querySelectorAll('[data-line="' + line + '"]'));
      return els.find(el => el.tagName === 'LI' || el.parentElement === content) || els[0] || null;
    },

    _diffTopLevel(el) {
      const content = document.getElementById('mr-content');
      while (el && el.parentElement && el.parentElement !== content) el = el.parentElement;
      return el;
    },

    // 旧版内容不参与行号体系（滚动同步、批注定位、段落批注都只认新文档）
    _diffDetach(root) {
      root.querySelectorAll('[data-line]').forEach(e => {
        e.removeAttribute('data-line');
        e.removeAttribute('data-line-end');
      });
      root.querySelectorAll('[id]').forEach(e => e.removeAttribute('id'));
    },

    applyDiff(diff) {
      MR._diff = diff || null;
      document.body.classList.toggle('mr-diff-mode', !!diff);
      const content = document.getElementById('mr-content');
      if (!content || !diff) return;
      (diff.marks || []).forEach(m => {
        const el = MR._diffFindBlock(m.line, m.kind);
        if (!el) return;
        if (m.status === 'added') {
          el.classList.add('mr-diff-added');
        } else {
          el.classList.add('mr-diff-modified');
          MR._diffModified(el, m);
        }
      });
      (diff.removed || []).forEach(r => MR._diffInsertRemoved(r));
    },

    _diffInsertRemoved(r) {
      const content = document.getElementById('mr-content');
      const prev = MR._diffFindAnchor(r.afterLine);
      const next = MR._diffFindAnchor(r.beforeLine);
      const tmp = document.createElement('div');
      tmp.innerHTML = r.html;
      MR._diffDetach(tmp);

      // 被删除的列表项：直接作为 <li> 插回相邻列表，保持缩进与圆点
      if (r.kind === 'listItem') {
        const li = tmp.querySelector('li');
        if (li && next && next.tagName === 'LI') { li.classList.add('mr-diff-removed'); next.before(li); return; }
        if (li && prev && prev.tagName === 'LI') { li.classList.add('mr-diff-removed'); prev.after(li); return; }
      }
      const wrap = document.createElement('div');
      wrap.className = 'mr-diff-removed';
      while (tmp.firstChild) wrap.appendChild(tmp.firstChild);
      if (next) {
        (next.tagName === 'LI' && r.kind !== 'listItem' ? MR._diffTopLevel(next) : next).before(wrap);
      } else if (prev) {
        (prev.tagName === 'LI' && r.kind !== 'listItem' ? MR._diffTopLevel(prev) : prev).after(wrap);
      } else {
        content.appendChild(wrap);
      }
    },

    // 修改块：代码 / 分隔线等整体显示旧版；表格按行对齐；其余做逐词 diff
    _diffModified(el, m) {
      if (m.oldHTML == null) return;
      if (m.kind === 'table') {
        if (!MR._diffTable(el, m.oldHTML)) MR._diffShowOld(el, m.oldHTML);
        return;
      }
      if (m.kind === 'code' || m.kind === 'thematicBreak' || m.kind === 'html' || m.kind === 'other') {
        MR._diffShowOld(el, m.oldHTML);
        return;
      }
      const tmp = document.createElement('div');
      tmp.innerHTML = m.oldHTML;
      const oldRoot = m.kind === 'listItem' ? (tmp.querySelector('li') || tmp) : tmp;
      if (!MR._diffWords(el, MR._diffText(oldRoot), false)) MR._diffShowOld(el, m.oldHTML);
    },

    _diffShowOld(el, oldHTML) {
      const tmp = document.createElement('div');
      tmp.innerHTML = oldHTML;
      MR._diffDetach(tmp);
      if (el.tagName === 'LI') {
        const li = tmp.querySelector('li');
        if (li) { li.classList.add('mr-diff-removed'); el.before(li); return; }
      }
      const wrap = document.createElement('div');
      wrap.className = 'mr-diff-removed';
      while (tmp.firstChild) wrap.appendChild(tmp.firstChild);
      el.before(wrap);
    },

    // 参与逐词 diff 的文本节点：跳过批注新增 / 评论（比较时已被还原掉）与已插入的删除片段
    _diffTextNodes(root) {
      const nodes = [];
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
        acceptNode(n) {
          const p = n.parentElement;
          const skip = p && p.closest('.critic-add, .critic-comment, .mr-diff-del, .mr-copy-btn, script, style');
          return (skip && root.contains(skip)) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
        }
      });
      while (walker.nextNode()) nodes.push(walker.currentNode);
      return nodes;
    },

    _diffText(root) {
      return MR._diffTextNodes(root).map(n => n.nodeValue).join('');
    },

    // 分词：中日韩逐字，拉丁文按词，空白与标点各自成词
    _diffTokens(text) {
      return text.match(/[぀-ヿ㐀-鿿豈-﫿가-힯]|[A-Za-z0-9_À-ɏ]+|\s+|[^\s]/g) || [];
    },

    // 通用 LCS：返回 {t:'e'|'d'|'i', i, j} 序列，同一段差异内删除在前、新增在后。超出规模返回 null。
    _lcs(a, b, limit) {
      const n = a.length, m = b.length;
      let pre = 0;
      while (pre < n && pre < m && a[pre] === b[pre]) pre++;
      let suf = 0;
      while (suf < n - pre && suf < m - pre && a[n - 1 - suf] === b[m - 1 - suf]) suf++;
      const an = n - pre - suf, bm = m - pre - suf;
      if (an * bm > (limit || 2000000)) return null;
      const ops = [];
      for (let k = 0; k < pre; k++) ops.push({ t: 'e', i: k, j: k });
      const w = bm + 1;
      const dp = new Int32Array((an + 1) * w);
      for (let i = an - 1; i >= 0; i--) {
        for (let j = bm - 1; j >= 0; j--) {
          dp[i * w + j] = a[pre + i] === b[pre + j]
            ? dp[(i + 1) * w + j + 1] + 1
            : Math.max(dp[(i + 1) * w + j], dp[i * w + j + 1]);
        }
      }
      let i = 0, j = 0, dels = [], ins = [];
      while (i < an || j < bm) {
        if (i < an && j < bm && a[pre + i] === b[pre + j]) {
          ops.push(...dels, ...ins); dels = []; ins = [];
          ops.push({ t: 'e', i: pre + i, j: pre + j }); i++; j++;
        } else if (j >= bm || (i < an && dp[(i + 1) * w + j] >= dp[i * w + j + 1])) {
          dels.push({ t: 'd', i: pre + i }); i++;
        } else {
          ins.push({ t: 'i', j: pre + j }); j++;
        }
      }
      ops.push(...dels, ...ins);
      for (let k = 0; k < suf; k++) ops.push({ t: 'e', i: n - suf + k, j: m - suf + k });
      return ops;
    },

    // 在 el 的文本上叠加逐词 diff。force=false 时改动过碎（超过六成）返回 false，由调用方改为整块对照。
    _diffWords(el, oldText, force) {
      const newText = MR._diffText(el);
      const a = MR._diffTokens(oldText), b = MR._diffTokens(newText);
      const ops = MR._lcs(a, b, 1500000);
      if (!ops) return false;

      const edits = [];   // {type:'ins', s, e} | {type:'del', at, text}
      let pos = 0, changed = 0;
      for (const op of ops) {
        if (op.t === 'e') { pos += b[op.j].length; continue; }
        if (op.t === 'i') {
          const len = b[op.j].length;
          const last = edits[edits.length - 1];
          if (last && last.type === 'ins' && last.e === pos) last.e += len;
          else edits.push({ type: 'ins', s: pos, e: pos + len });
          pos += len;
        } else {
          const tok = a[op.i];
          const last = edits[edits.length - 1];
          if (last && last.type === 'del' && last.at === pos) last.text += tok;
          else edits.push({ type: 'del', at: pos, text: tok });
        }
      }
      const real = edits.filter(e => e.type === 'del'
        ? e.text.trim() !== ''
        : newText.slice(e.s, e.e).trim() !== '');
      real.forEach(e => { changed += e.type === 'del' ? e.text.length : (e.e - e.s); });
      // 改动字符（删 + 增）超过两版总长的一半：逐词标记会碎成一片，不如整块对照
      if (!force && changed > 0.5 * (oldText.length + newText.length)) return false;

      // 从后往前应用，前面的偏移不受影响；同一位置先插删除片段再包新增
      real.sort((x, y) => {
        const px = x.type === 'del' ? x.at : x.s, py = y.type === 'del' ? y.at : y.s;
        if (px !== py) return py - px;
        return x.type === 'del' ? -1 : 1;
      });
      for (const e of real) {
        if (e.type === 'del') MR._diffInsertDel(el, e.at, e.text);
        else MR._diffWrapIns(el, e.s, e.e);
      }
      return true;
    },

    _diffInsertDel(root, at, text) {
      const span = document.createElement('span');
      span.className = 'mr-diff-del';
      span.textContent = text;
      const nodes = MR._diffTextNodes(root);
      let start = 0;
      for (const n of nodes) {
        const len = n.nodeValue.length;
        if (at < start + len || (at === start + len && n === nodes[nodes.length - 1])) {
          const off = at - start;
          if (off === 0) n.parentNode.insertBefore(span, n);
          else if (off === len) n.parentNode.insertBefore(span, n.nextSibling);
          else n.parentNode.insertBefore(span, n.splitText(off));
          return;
        }
        start += len;
      }
      root.appendChild(span);
    },

    _diffWrapIns(root, s, e) {
      const nodes = MR._diffTextNodes(root);
      let start = 0;
      for (const n of nodes) {
        const len = n.nodeValue.length;
        const ns = start, ne = start + len;
        start = ne;
        if (ne <= s || ns >= e) continue;
        let target = n;
        const from = Math.max(s, ns) - ns, to = Math.min(e, ne) - ns;
        if (to < len) target.splitText(to);
        if (from > 0) target = target.splitText(from);
        const span = document.createElement('span');
        span.className = 'mr-diff-ins';
        target.parentNode.insertBefore(span, target);
        span.appendChild(target);
      }
    },

    // 表格：按行对齐（行文本做 LCS），相似的删除 / 新增行配成修改行做逐格 diff。列数变化返回 false。
    _diffTable(el, oldHTML) {
      const tmp = document.createElement('div');
      tmp.innerHTML = oldHTML;
      const oldTable = tmp.querySelector('table');
      if (!oldTable) return false;
      MR._diffDetach(tmp);
      const cellsOf = tr => Array.from(tr.children);
      const oldHead = oldTable.querySelector('thead tr'), newHead = el.querySelector('thead tr');
      if (!oldHead || !newHead || cellsOf(oldHead).length !== cellsOf(newHead).length) return false;

      const rowKey = tr => cellsOf(tr).map(c => MR._diffText(c).trim()).join('\t');
      if (rowKey(oldHead) !== rowKey(newHead)) MR._diffRow(newHead, oldHead);

      const oldRows = Array.from(oldTable.querySelectorAll('tbody tr'));
      const newRows = Array.from(el.querySelectorAll('tbody tr'));
      const ops = MR._lcs(oldRows.map(rowKey), newRows.map(rowKey), 1000000);
      if (!ops) return false;
      let tbody = el.querySelector('tbody');
      if (!tbody) { tbody = document.createElement('tbody'); el.appendChild(tbody); }

      let dels = [];
      const flush = (beforeRow) => {
        dels.forEach(tr => {
          tr.classList.add('mr-diff-removed');
          if (beforeRow) tbody.insertBefore(tr, beforeRow); else tbody.appendChild(tr);
        });
        dels = [];
      };
      // 两行至少半数单元格相同才算「同一行被修改」
      const similarRows = (x, y) => {
        const xc = cellsOf(x), yc = cellsOf(y);
        if (xc.length !== yc.length) return false;
        let same = 0;
        xc.forEach((c, k) => { if (MR._diffText(c).trim() === MR._diffText(yc[k]).trim()) same++; });
        return same * 2 >= xc.length;
      };
      for (const op of ops) {
        if (op.t === 'd') { dels.push(oldRows[op.i]); continue; }
        const row = newRows[op.j];
        if (op.t === 'e') { flush(row); continue; }
        // 新增行：与待定删除行中相似的一行配成修改行；它之前的删除行先落位
        const k = dels.findIndex(d => similarRows(d, row));
        if (k >= 0) {
          const pair = dels[k];
          const before = dels.slice(0, k);
          dels = dels.slice(k + 1);
          before.forEach(tr => { tr.classList.add('mr-diff-removed'); tbody.insertBefore(tr, row); });
          MR._diffRow(row, pair);
        } else {
          row.classList.add('mr-diff-added');
        }
      }
      flush(null);
      return true;
    },

    _diffRow(newRow, oldRow) {
      newRow.classList.add('mr-diff-modified');
      const oc = Array.from(oldRow.children), nc = Array.from(newRow.children);
      nc.forEach((cell, k) => {
        const oldText = oc[k] ? MR._diffText(oc[k]) : '';
        if (oldText.trim() !== MR._diffText(cell).trim()) MR._diffWords(cell, oldText, true);
      });
    },

    // 跳到上一处 / 下一处改动（dir: 1 / -1），返回 [当前序号, 总数]
    diffNavigate(dir) {
      const sel = '.mr-diff-added, .mr-diff-modified, .mr-diff-removed';
      const all = Array.from(document.querySelectorAll('#mr-content ' + sel))
        .filter(el => !(el.parentElement && el.parentElement.closest(sel)));
      if (!all.length) return [0, 0];
      const anchor = 90;
      let idx;
      if (dir > 0) {
        idx = all.findIndex(el => el.getBoundingClientRect().top > anchor + 2);
        if (idx < 0) idx = 0;
      } else {
        idx = -1;
        all.forEach((el, k) => { if (el.getBoundingClientRect().top < anchor - 2) idx = k; });
        if (idx < 0) idx = all.length - 1;
      }
      const target = all[idx];
      window.scrollBy({ top: target.getBoundingClientRect().top - anchor, behavior: 'smooth' });
      target.classList.remove('mr-diff-flash');
      void target.offsetWidth;
      target.classList.add('mr-diff-flash');
      return [idx + 1, all.length];
    },

    // ===== 段落批注：块间悬停「+」 =====

    // 只含评论标记的段落 = 段落批注：展开显示评论内容，而不是只有一个 💬 角标
    renderBlockComments() {
      const content = document.getElementById('mr-content');
      if (!content) return;
      content.querySelectorAll(':scope > p').forEach(p => {
        const nodes = Array.from(p.childNodes);
        const bubbles = nodes.filter(n => n.nodeType === 1 && n.classList.contains('critic-comment'));
        const onlyComments = bubbles.length > 0 && nodes.every(n =>
          (n.nodeType === 3 && !n.textContent.trim()) ||
          (n.nodeType === 1 && (n.classList.contains('critic-comment') || n.tagName === 'BR')));
        if (!onlyComments) return;
        p.classList.add('mr-block-comment');
        bubbles.forEach(b => {
          b.textContent = '';
          const icon = document.createElement('span');
          icon.className = 'mr-block-comment-icon';
          icon.textContent = '\u{1F4AC}';
          const text = document.createElement('span');
          text.className = 'mr-block-comment-text';
          text.textContent = b.dataset.comment || '';
          b.appendChild(icon);
          b.appendChild(text);
        });
      });
    },

    // 可挂段落批注的块：#mr-content 的直接子元素且带源码末行号
    _blockCandidates() {
      const content = document.getElementById('mr-content');
      if (!content) return [];
      return Array.from(content.children).filter(el => el.dataset && el.dataset.lineEnd);
    },

    _hideBlockAdd() {
      const btn = document.getElementById('mr-block-add');
      if (btn) btn.classList.remove('visible');
      if (MR._blockAddTarget) MR._blockAddTarget.classList.remove('mr-block-target');
      MR._blockAddTarget = null;
    },

    // 根据鼠标位置决定「+」挂在哪个块下方：鼠标所在（或其上方最近）的块，按钮放在它与下一块之间的空隙
    _updateBlockAdd(x, y) {
      const btn = document.getElementById('mr-block-add');
      const content = document.getElementById('mr-content');
      if (!btn || !content) return;
      const bar = document.getElementById('mr-critic-toolbar');
      const sel = window.getSelection();
      if ((bar && bar.classList.contains('visible')) || (sel && !sel.isCollapsed)) { MR._hideBlockAdd(); return; }

      const cRect = content.getBoundingClientRect();
      if (x < cRect.left - 48 || x > cRect.right || y < cRect.top || y > cRect.bottom + 24) {
        MR._hideBlockAdd();
        return;
      }
      const blocks = MR._blockCandidates();
      let idx = -1;
      for (let i = 0; i < blocks.length; i++) {
        if (blocks[i].getBoundingClientRect().top <= y) idx = i; else break;
      }
      if (idx < 0) { MR._hideBlockAdd(); return; }
      const block = blocks[idx];
      const rect = block.getBoundingClientRect();
      const nextTop = idx + 1 < blocks.length ? blocks[idx + 1].getBoundingClientRect().top : rect.bottom + 16;
      const gapMid = rect.bottom + Math.max(0, nextTop - rect.bottom) / 2;

      if (MR._blockAddTarget !== block) {
        if (MR._blockAddTarget) MR._blockAddTarget.classList.remove('mr-block-target');
        MR._blockAddTarget = block;
      }
      const size = 18;
      const left = Math.max(2, cRect.left - size - 6);
      btn.style.left = (left + window.scrollX) + 'px';
      btn.style.top = (gapMid - size / 2 + window.scrollY) + 'px';
      btn.classList.add('visible');
    },

    _promptBlockComment(block, rect) {
      const line = parseInt(block.dataset.lineEnd) || 0;
      if (!line) return;
      const bar = MR._ensureCriticToolbar();
      // 复用选词评论的输入框：pending.text 为空、line 为块末行，提交时 op = blockComment
      MR._criticPending = { text: '', line: line };
      MR._criticRange = null;
      MR._criticAnchorRect = rect;
      const L = MR.criticLabels;
      bar.classList.add('visible');
      MR._promptCritic('blockComment', L.blockCommentHint || L.commentHint, true);
      // 输入框放在「+」下方、与正文左对齐：不遮挡被批注的那一段
      const content = document.getElementById('mr-content');
      const cRect = content ? content.getBoundingClientRect() : rect;
      const barRect = bar.getBoundingClientRect();
      let top = rect.bottom + 6;
      if (top + barRect.height > window.innerHeight - 4) top = Math.max(4, rect.top - barRect.height - 6);
      bar.style.top = top + 'px';
      bar.style.left = Math.max(4, Math.min(cRect.left, window.innerWidth - barRect.width - 4)) + 'px';
    },

    _initBlockCommentGutter() {
      if (MR._isReadonly() || document.getElementById('mr-block-add')) return;
      const btn = document.createElement('button');
      btn.id = 'mr-block-add';
      btn.type = 'button';
      btn.innerHTML = '<svg viewBox="0 0 12 12" width="10" height="10" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M6 1.5v9M1.5 6h9"/></svg>';
      document.body.appendChild(btn);

      // 不抢焦点、不清选区，也不触发「点击空白关闭弹窗」
      btn.addEventListener('mousedown', (e) => { e.preventDefault(); e.stopPropagation(); });
      btn.addEventListener('mouseenter', () => {
        btn.title = MR.criticLabels.blockComment || '';
        if (MR._blockAddTarget) MR._blockAddTarget.classList.add('mr-block-target');
      });
      btn.addEventListener('mouseleave', () => {
        if (MR._blockAddTarget) MR._blockAddTarget.classList.remove('mr-block-target');
      });
      btn.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation();
        const block = MR._blockAddTarget;
        const rect = btn.getBoundingClientRect();
        MR._hideBlockAdd();
        if (block) MR._promptBlockComment(block, rect);
      });

      let pending = null;
      document.addEventListener('mousemove', (e) => {
        if (e.target === btn) return;
        const x = e.clientX, y = e.clientY;
        if (pending) cancelAnimationFrame(pending);
        pending = requestAnimationFrame(() => { pending = null; MR._updateBlockAdd(x, y); });
      });
      document.addEventListener('mouseleave', () => MR._hideBlockAdd());
    },

    _initCriticSelection() {
      const readonly = this._isReadonly();

      // 点击已有评论气泡 → 弹出查看（只读环境无编辑/删除按钮，见 _showCommentPopover）。
      // 该查看能力在只读环境下也保留，便于阅读评论内容。
      document.addEventListener('click', (e) => {
        const bubble = e.target.closest && e.target.closest('.critic-comment');
        if (bubble) {
          e.preventDefault();
          e.stopPropagation();
          MR._showCommentPopover(bubble);
        }
      });

      // 点击空白处隐藏评论弹窗（可写环境下还兼顾工具条输入态兜底；只读环境下工具条不存在，分支自然空转）
      document.addEventListener('mousedown', (e) => {
        const pop = document.getElementById('mr-critic-popover');
        const bar = document.getElementById('mr-critic-toolbar');
        const inPop = pop && pop.contains(e.target);
        const inBar = bar && bar.contains(e.target);
        const onBubble = e.target.closest && e.target.closest('.critic-comment');
        if (!inPop && !onBubble) {
          // 防误关：编辑已有评论且输入框有内容时，点击外部不关闭（issue #7）
          const popField = pop && pop.classList.contains('critic-input-mode') && pop.querySelector('.critic-field');
          if (!(popField && popField.value.trim())) MR._hideCommentPopover();
        }
        if (!inBar && !inPop && bar && bar.classList.contains('critic-input-mode')) {
          const field = bar.querySelector('.critic-field');
          if (!(field && field.value.trim())) MR._hideCriticToolbar();
        }
      });

      // 选词标注工具条仅在可写环境提供：只读环境（QuickLook / 导出 HTML）无法保存标注。
      if (readonly) return;

      const onSelectionChange = () => {
        // 输入态（评论/替换正在输入）时不刷新工具条
        const bar = document.getElementById('mr-critic-toolbar');
        if (bar && bar.classList.contains('critic-input-mode')) return;

        const sel = window.getSelection();
        if (!sel || sel.isCollapsed || sel.rangeCount === 0) {
          MR._hideCriticToolbar();
          return;
        }
        const text = sel.toString();
        if (!text || !text.trim()) { MR._hideCriticToolbar(); return; }

        const range = sel.getRangeAt(0);
        const content = document.getElementById('mr-content');
        if (!content || !content.contains(range.commonAncestorContainer)) {
          MR._hideCriticToolbar();
          return;
        }
        // 选区完全落在已有标注（删除 / 新增 / 高亮）内部：CriticMarkup 不能嵌套，不提供标注入口
        const elOf = n => (n && n.nodeType === 3) ? n.parentElement : n;
        const inA = elOf(range.startContainer) && elOf(range.startContainer).closest('.critic');
        const inB = elOf(range.endContainer) && elOf(range.endContainer).closest('.critic');
        if (inA && inA === inB) { MR._hideCriticToolbar(); return; }
        const rect = range.getBoundingClientRect();
        if (rect.width === 0 && rect.height === 0) { MR._hideCriticToolbar(); return; }
        MR._criticRange = range.cloneRange();
        const line = MR._criticLineFor(range.startContainer);
        MR._showCriticToolbar(range, text, line);
      };

      document.addEventListener('selectionchange', () => {
        clearTimeout(MR._criticSelTimer);
        MR._criticSelTimer = setTimeout(onSelectionChange, 120);
      });
    },

    init() {
      MR.applyDiff(window.MR_DIFF || null);
      MR.renderMermaid();
      MR.renderPlantUML();
      MR.renderKaTeX();
      MR.renderAdmonitions();
      MR.renderBlockComments();
      MR.addCopyButtons();
      MR._initCriticSelection();
      MR._initBlockCommentGutter();
      if (typeof Prism !== 'undefined') {
        Prism.highlightAll();
      }
    }
  };

  window.MR = MR;

  // ---- 滚动同步：通过 WKScriptMessageHandler 上报可见行 / 标题（替代旧 SwiftUI scrollGeometry 回调）----
  function postScrollSync() {
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.scrollSync) {
        window.webkit.messageHandlers.scrollSync.postMessage({
          line: MR.getTopVisibleLine(),
          heading: MR.getVisibleHeading()
        });
      }
    } catch (e) { /* no-op */ }
  }

  let _mrScrollTimer = null;
  window.addEventListener('scroll', function() {
    if (_mrScrollTimer) clearTimeout(_mrScrollTimer);
    _mrScrollTimer = setTimeout(postScrollSync, 200);
  }, { passive: true });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', MR.init);
  } else {
    MR.init();
  }
})();
