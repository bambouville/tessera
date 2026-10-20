/* Illustrative reports only. No host, transport, network, or command APIs. */
(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const states = {
    approval: { state: 'blocked', label: 'needs approval', kind: 'permission', message: 'Run swift test --package-path Packages/TesseraCore?', terminal: 'Claude Code\n\nThe session restore path is updated.\n\nClaude wants to run:\n  swift test --package-path Packages/TesseraCore\n\n  1. Allow once\n  2. Deny\n\n›' },
    question: { state: 'blocked', label: 'needs an answer', kind: 'question', message: 'Wait for the foreground transition before restoring?', terminal: 'Claude Code\n\nWait for the foreground transition before restoring?\n\n  1. Wait until the session is visible\n  2. Restore immediately\n\n›' },
    auth: { state: 'blocked', label: 'sign-in needed', kind: 'auth', message: 'Sign in to continue', terminal: 'Claude Code\n\nSign in to continue.\n\nComplete sign-in in your browser, then return here.\n\n›' },
    working: { state: 'working', label: 'working', message: 'Checking the affected tests', progress: 60, terminal: 'Claude Code\n\n• Updated the session restore path\n• Running affected tests\n\n  Checking the affected tests · 60%' },
    done: { state: 'done', label: 'finished', message: 'Restore fix is ready. All affected tests passed.', terminal: 'Claude Code\n\nThe session restore path is updated.\n\nValidation:\n  All affected tests passed.\n\nReady for your review.\n\n›' },
    error: { state: 'error', label: 'failed', message: 'Test fixture could not be prepared.', terminal: 'Claude Code\n\nTest fixture could not be prepared.\n\nerror: simulator fixture is unavailable\n\nValidation did not complete.\n\n›' },
    idle: { state: 'idle', label: 'ready', message: 'Waiting for your next task', terminal: 'Claude Code\n\n›' },
    offline: { state: 'unavailable', label: 'status unavailable', message: 'needs approval · 2 min ago', terminal: 'Last visible output · historical\n\nClaude wants to run:\n  swift test --package-path Packages/TesseraCore\n\nThe status channel is unavailable.' }
  };
  const windows = {
    claude: { key: 'claude', session: 'devbox', window: 'agent', number: 1, pane: '%4', command: 'claude', agent: true, app: 'Claude Code', title: 'fix session restore' },
    terraform: { key: 'terraform', session: 'devbox', window: 'deploy', number: 2, pane: '%7', command: 'terraform', app: 'terraform', title: 'apply · prod', state: 'blocked', label: 'needs approval', kind: 'permission', message: 'Apply 3 to add, 1 to change, 0 to destroy?', terminal: '$ terraform apply\n\nPlan: 3 to add, 1 to change, 0 to destroy.\n\nDo you want to perform these actions?\n  Only \'yes\' will be accepted to approve.\n\n  Enter a value:' },
    cargo: { key: 'cargo', session: 'devbox', window: 'build', number: 3, pane: '%9', command: 'cargo', panes: [{ id: '%9', title: 'cargo build', command: 'cargo' }, { id: '%10', title: 'zsh', command: 'zsh' }], app: 'cargo', state: 'working', label: 'working', message: 'Compiling dependencies', progress: 42, terminal: '$ cargo build\n\n   Compiling serde v1.0.228\n   Compiling app v0.1.0\n\n   Building [42%] …' },
    logs: { key: 'logs', session: 'devbox', window: 'logs', number: 4, pane: '%11', command: 'tail', terminal: '$ tail -f /var/log/app.log\n\n10:42:01  ready to accept connections\n10:42:03  request completed  200  12ms\n10:42:04  request completed  200   8ms\n\n' },
    codex: { key: 'codex', session: 'staging', window: 'tests', number: 1, pane: '%12', command: 'codex', agent: true, app: 'Codex', title: 'review transport tests', state: 'working', label: 'working', message: 'Reviewing reconnect coverage', terminal: 'Codex\n\n• Reading integration tests\n• Checking reconnect behavior\n\n  Reviewing reconnect coverage' }
  };
  const hostKeys = { devbox: 'dev@devbox', staging: 'dev@staging' };
  let session = 'devbox', view = 'terminal', rootSegment = 'sessions', thread = 'claude';
  let sidebarShown = false, threadDetail = false, seen = false, overlay = null, overlayReturn = null;
  // Preserve the last focused window separately for each live session.
  const active = { devbox: 'logs', staging: 'codex' };
  let historicalRow = false;
  const phone = () => $('layout').value === 'phone';
  const raw = () => $('transport').value === 'ssh';
  const android = () => $('platform').value === 'android';
  const agentCenter = () => $('agentcenter').value === 'on';
  const feedback = text => { $('preview-feedback').textContent = text; };
  function element(tag, cls, text) {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined) node.textContent = text;
    return node;
  }
  function action(cls, label, callback) {
    const node = element('button', cls);
    node.type = 'button'; node.setAttribute('aria-label', label);
    node.addEventListener('click', callback);
    return node;
  }
  function proposed(node, condition = true) { node.classList.toggle('proposed', condition); return node; }
  function record(key) {
    const r = { ...windows[key] };
    if (key === 'claude') Object.assign(r, states[$('scenario').value], { seen });
    // Without Agent Center nothing verifies an agent: its own reports are a
    // generic program's, governed only by the program status switch.
    if (!agentCenter()) r.agent = false;
    if (!r.agent && $('programs').value === 'hidden') {
      delete r.state; delete r.app; delete r.message; delete r.progress;
      delete r.label; delete r.kind; delete r.title;
    }
    return r;
  }
  function allRecords() {
    return (raw() ? ['claude'] : ['claude', 'terraform', 'cargo', 'codex']).map(record).filter(r => r.state);
  }
  function sessionWindows(host = session) {
    return (raw() ? ['claude'] : host === 'devbox' ? ['claude', 'terraform', 'cargo', 'logs'] : ['codex']).map(record);
  }
  function selectedKey() { return raw() ? 'claude' : active[session]; }
  function attention(r) {
    if (r.state === 'blocked') return 'amber';
    if (!r.seen && r.state === 'error') return 'red';
    if (!r.seen && r.state === 'done') return 'green';
    return '';
  }
  function cue(r, isActive = false) {
    const tone = attention(r);
    return isActive && tone !== 'amber' ? '' : tone;
  }
  function attentionRecords() {
    const rank = { amber: 0, red: 1, green: 2 };
    return allRecords().filter(r => attention(r)).sort((a, b) => rank[attention(a)] - rank[attention(b)]);
  }
  function location(r) {
    return `${r.session} · ${raw() && r.session === 'devbox' ? 'raw session' : `window ${r.number} “${r.window}” · pane ${r.pane}`}`;
  }
  // One vocabulary for agents and other programs; the sparkles glyph, not a
  // noun, marks a pane that hosts a detected agent.
  function summary(rs) {
    const counts = { amber: 0, red: 0, green: 0 };
    rs.forEach(r => { const tone = attention(r); if (tone) counts[tone]++; });
    const parts = [];
    for (const [tone, one, many] of [['amber', 'needs input', 'need input'], ['red', 'failed', 'failed'], ['green', 'finished', 'finished']]) {
      const n = counts[tone];
      if (n) parts.push(`${n} ${n === 1 ? one : many}`);
    }
    return parts.join(' · ');
  }
  // Row counterpart of the chip: per-state parts, each in its own tint, with
  // the specific words ("1 needs approval") when they are unambiguous.
  const plural = { 'needs approval': 'need approval', 'needs an answer': 'need an answer', 'needs input': 'need input' };
  function rowSummary(rs) {
    return ['amber', 'red', 'green'].map(tone => {
      const group = rs.filter(r => attention(r) === tone);
      if (!group.length) return null;
      const labels = [...new Set(group.map(r => r.label))];
      const word = labels.length === 1 ? labels[0] : 'needs input';
      return { tone, text: `${group.length} ${group.length === 1 ? word : plural[word] || word}` };
    }).filter(Boolean);
  }
  function summaryNodes(parts, lead = '') {
    const nodes = [];
    parts.forEach((part, i) => nodes.push(element('span', part.tone, `${i || lead ? ' · ' : ''}${part.text}`)));
    return nodes;
  }
  function statusWords(r, isActive = false) {
    if (!r.state) return null;
    if (r.state === 'unavailable') return { text: 'status unavailable', tone: 'dim' };
    const tone = cue(r, isActive);
    return { text: `${r.label}${r.progress !== undefined ? ` · ${r.progress}%` : ''}`, tone: tone || 'dim' };
  }
  function a11yWindow(r, isActive) {
    const tone = cue(r, isActive);
    const state = r.agent ? tone === 'amber' ? 'agent needs input' : tone === 'green' ? 'agent just finished' : tone === 'red' ? 'agent failed' : 'agent active' : r.state ? `program ${r.label}` : '';
    return `${r.window}, window ${r.number}${state ? `, ${state}` : ''}`;
  }
  function closePanels(restoreFocus = true) {
    const target = overlayReturn;
    overlay = null; overlayReturn = null; historicalRow = false;
    for (const id of ['activity', 'session-picker', 'status-popover', 'utility-panel', 'backdrop']) $(id).hidden = true;
    $('backdrop').classList.remove('palette-scrim');
    $('activity-button').setAttribute('aria-expanded', 'false');
    $('session-picker-button').setAttribute('aria-expanded', 'false');
    if (restoreFocus && target && target.isConnected && !target.hidden) target.focus();
  }
  function openOverlay(name, trigger) {
    if (overlay === name) { closePanels(); feedback('closed the preview'); return; }
    closePanels(false); overlay = name; overlayReturn = trigger;
    $(name).hidden = false; $('backdrop').hidden = false;
    if (name === 'activity') {
      $('activity-button').setAttribute('aria-expanded', 'true');
      renderActivity(); anchorPopover();
    }
    if (name === 'session-picker' || name === 'status-popover') $('session-picker-button').setAttribute('aria-expanded', 'true');
    if (name === 'session-picker') $('backdrop').classList.add('palette-scrim');
    if (name === 'status-popover') { renderPrograms(); anchorStatus(); }
    $(name).querySelector('button:not(:disabled)')?.focus();
    feedback(name === 'activity' ? 'opened attention; no results checked' : name === 'status-popover' ? 'opened connection status; no results checked' : 'opened the switcher; no results checked');
  }
  function visit(key) {
    const r = record(key);
    session = r.session; active[session] = key; view = 'terminal';
    const checked = key === 'claude' && ['done', 'error'].includes(r.state) && !seen;
    if (checked) seen = true;
    closePanels(false); render();
    const name = raw() ? 'raw session' : `window ${r.number} “${r.window}”`;
    feedback(`visited ${name}${checked ? `; the ${r.label} result is now checked` : ''}`);
    (phone() ? $('session-picker-button') : $('window-strip').querySelector(`[data-window="${key}"]`) || $('session-picker-button')).focus();
  }
  function switchSession(host) {
    session = host; view = 'terminal'; closePanels(false); render();
    // Switching sessions reveals its retained active pane, just like a tab visit.
    visit(selectedKey());
  }
  function openAgentCenter(key = null) {
    if (!agentCenter()) return;
    if (key) thread = key;
    threadDetail = Boolean(key);
    if (phone()) { view = 'root'; rootSegment = 'agents'; } else view = 'agents';
    closePanels(false); render(); feedback(key ? `viewing ${record(key).title}` : 'opened agent center; no results checked');
  }
  function sparkle(r, tone, cls = '') {
    const node = element('span', `sparkle ${cls} ${tone ? `${tone} attention` : ''}`, '✧');
    node.setAttribute('role', 'img');
    node.setAttribute('aria-label', tone === 'amber' ? 'agent needs input' : tone === 'green' ? 'agent just finished' : tone === 'red' ? 'agent failed' : 'agent active');
    return proposed(node, android() || tone === 'red');
  }
  function sessionRow(host, root = false) {
    const rs = allRecords().filter(r => r.session === host);
    const agents = rs.filter(r => r.agent), agentAttention = agents.filter(r => attention(r));
    const node = action(`session-row ${host === session ? 'selected' : ''}`, `${host}, connected`, () => switchSession(host));
    const dot = element('span', 'connection-dot'); dot.setAttribute('aria-hidden', 'true');
    const copy = element('span', 'session-copy');
    const name = element('span', 'session-name', host);
    if (!root && !raw()) name.append(element('span', 'dim', ' · tmux'));
    const sub = element('div', 'session-subtitle', root ? `${host === 'staging' ? 'ssh+tmux' : $('transport').value.replace('-tmux', '+tmux')} · connected` : 'connected');
    const parts = rowSummary(attentionRecords().filter(r => r.session === host));
    if (parts.length) {
      const words = proposed(element('span', 'row-summary')); words.append(...summaryNodes(parts, 'lead'));
      sub.append(words);
      node.setAttribute('aria-label', `${host}, connected, ${parts.map(p => p.text).join(', ')}`);
    }
    copy.append(name, sub); node.append(dot, copy);
    if (agents.length && !root) {
      const tone = agentAttention.length ? attention(agentAttention[0]) : '';
      node.append(sparkle(agents[0], tone, 'session-sparkle'));
    }
    if (root) node.append(element('span', 'dim', '›'));
    return node;
  }
  function renderSessions() {
    const hosts = raw() ? ['devbox'] : ['devbox', 'staging'];
    $('session-total').textContent = hosts.length;
    for (const id of ['sidebar-sessions', 'root-session-rows']) {
      $(id).replaceChildren();
      hosts.forEach(host => {
        const row = sessionRow(host, id === 'root-session-rows');
        if (id !== 'root-session-rows') { $(id).append(row); return; }
        const wrap = element('div', 'root-session-wrap');
        const disconnect = action('bar-icon root-disconnect', `disconnect ${host}`, () => showUtility('disconnect', `disconnect ${host}?`));
        disconnect.append(element('span', '', '×')); wrap.append(row, disconnect); $(id).append(wrap);
      });
    }
    const agents = allRecords().filter(r => r.agent);
    const waiting = agents.filter(r => attention(r) === 'amber').length;
    const finished = agents.filter(r => attention(r) === 'green').length;
    const failed = agents.filter(r => attention(r) === 'red').length;
    const badges = $('agent-badges'); badges.replaceChildren();
    for (const [n, tone, label] of [[waiting, 'amber', 'agents need input'], [failed, 'red', 'agents failed'], [finished, 'green', 'agents just finished'], [agents.length, '', 'agents total']]) {
      if (n) { const badge = proposed(element('span', `count ${tone}`, n), (android() && Boolean(tone)) || tone === 'red'); badge.setAttribute('aria-label', `${n} ${label}`); badges.append(badge); }
    }
    const count = attentionRecords().length;
    $('sessions-badge').hidden = !count; $('sessions-badge').textContent = count;
    const addedBadge = allRecords().some(r => attention(r) && (!r.agent || r.state === 'error'));
    proposed($('sessions-badge'), addedBadge || android());
    $('root-sessions-tab').setAttribute('aria-label', `sessions${count ? `, ${count} need attention` : ''}`);
    $('sidebar-agents').classList.toggle('selected', view === 'agents');
  }
  function renderWindows() {
    $('window-strip').replaceChildren();
    $('window-strip').hidden = raw(); $('new-window').hidden = raw();
    if (raw()) return;
    sessionWindows().forEach(r => {
      const isActive = r.key === selectedKey(), tone = cue(r, isActive), result = tone === 'green' || tone === 'red';
      const tab = element('div', `window-tab ${isActive ? 'active' : ''} ${tone} ${result ? 'result' : ''}`);
      proposed(tab, Boolean(tone) && (android() || !r.agent || tone === 'red'));
      const select = action('window-select', a11yWindow(r, isActive), () => visit(r.key));
      select.dataset.window = r.key; select.setAttribute('aria-current', isActive ? 'page' : 'false');
      if (r.agent) select.append(sparkle(r, tone));
      select.append(element('span', 'window-name', r.window), element('span', 'shortcut', `⌘${r.number}`));
      const close = action('window-close', `Close ${r.window}`, () => showUtility('close window', `close window ${r.number} “${r.window}”?`));
      close.append(element('span', '', '×')); tab.append(select, close);
      if (tone) tab.append(proposed(element('span', `underline ${tone}`), android() || !r.agent || tone === 'red'));
      $('window-strip').append(tab);
    });
  }
  const icons = {
    terminal: '<rect x="1.5" y="2.5" width="13" height="11" rx="2"/><path d="m4.5 6 2 2-2 2M8.5 10h3"/>',
    split: '<rect x="1.5" y="2.5" width="13" height="11" rx="2"/><path d="M8 2.5v11"/>',
    home: '<path d="M2.5 7.5 8 3l5.5 4.5V13h-11z"/>'
  };
  function icon(name) {
    const node = element('span', 'palette-glyph');
    node.innerHTML = `<svg viewBox="0 0 16 16" aria-hidden="true">${icons[name]}</svg>`;
    return node;
  }
  // The phone's top-bar switcher (CommandPaletteView): home, this session's
  // windows and panes, then sessions. Status words join each row's subtitle.
  function paletteRow({ cls = '', glyph = null, title, titleTone = '', sub = '', words = null, current = false, handle = false, label, onClick }) {
    const row = action(`palette-row ${cls}`, label, onClick);
    const slot = element('span', 'palette-icon');
    if (glyph) slot.append(glyph); else if (cls === 'pane') slot.textContent = '↳';
    const copy = element('span', 'palette-copy');
    copy.append(proposed(element('span', `palette-title ${titleTone ? `${titleTone} result` : ''}`, title), Boolean(titleTone)));
    const line = element('span', 'palette-sub', sub);
    if (words) { if (sub) line.append(' · '); line.append(proposed(element('span', words.tone, words.text))); }
    copy.append(line); row.append(slot, copy);
    if (handle) { const grip = element('span', 'palette-handle', '≡'); grip.setAttribute('aria-hidden', 'true'); row.append(grip); }
    if (cls !== 'session') row.append(element('span', `palette-mark ${current ? 'current' : ''}`, current ? '●' : '↩'));
    return row;
  }
  function renderPalette() {
    const target = $('palette-results'); target.replaceChildren();
    target.append(paletteRow({ glyph: icon('home'), title: 'hosts home', sub: 'back to the tab bar · session keeps running', label: 'hosts home, back to the tab bar', onClick: () => showUtility('hosts', 'devbox · staging') }));
    const hosts = raw() ? ['devbox'] : ['devbox', 'staging'];
    const windowsShown = raw() ? [] : sessionWindows();
    if (windowsShown.length) target.append(element('div', 'palette-section', `windows · ${session}`));
    windowsShown.forEach(r => {
      const isActive = r.key === selectedKey(), tone = cue(r, isActive), words = statusWords(r, isActive);
      const panes = r.panes || [{ id: r.pane, title: r.window, command: r.command }], multi = panes.length > 1;
      const glyph = r.agent ? proposed(sparkle(r, tone)) : icon(multi ? 'split' : 'terminal');
      const sub = multi ? `${panes.length} panes${words ? '' : ' · each opens full-screen'}` : r.command;
      const rowWords = multi && words ? { ...words, text: `${r.app} ${words.text}` } : words;
      const spoken = `${r.window}, window ${r.number}${rowWords ? `, ${r.agent ? 'agent ' : ''}${rowWords.text}` : ''}${isActive ? ', current' : ''}`;
      target.append(paletteRow({ glyph, title: r.window, titleTone: tone === 'green' || tone === 'red' ? tone : '', sub, words: rowWords, current: isActive, handle: true, label: spoken, onClick: () => visit(r.key) }));
      if (multi) panes.forEach(p => {
        const own = p.id === r.pane ? words : null;
        target.append(paletteRow({ cls: 'pane', title: p.title, sub: `${p.id} · ${p.command}`, words: own, current: isActive && p.id === r.pane, label: `${p.title}, pane ${p.id}${own ? `, ${own.text}` : ''}`, onClick: () => visit(r.key) }));
      });
    });
    target.append(element('div', 'palette-section', 'sessions'));
    hosts.forEach(host => {
      const parts = rowSummary(attentionRecords().filter(r => r.session === host));
      const pane = host === session && !raw() ? ` · ${record(selectedKey()).window}` : '';
      const row = paletteRow({ cls: 'session', title: host, sub: `${hostKeys[host]}${pane}`, label: `session ${host}, ${hostKeys[host]}${parts.length ? `, ${parts.map(p => p.text).join(', ')}` : ''}`, onClick: () => switchSession(host) });
      const dot = element('span', 'connection-dot'); dot.setAttribute('aria-hidden', 'true');
      row.firstChild.append(dot);
      // A session can hold several records, so its status gets its own line.
      if (parts.length) { const line = proposed(element('span', 'palette-sub palette-status')); line.append(...summaryNodes(parts)); row.querySelector('.palette-copy').append(line); }
      target.append(row);
    });
    const count = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;
    $('palette-footer').textContent = `${count(windowsShown.length, 'window')} · ${count(hosts.length, 'session')}`;
  }
  function renderChip() {
    const rs = attentionRecords(), generic = rs.some(r => !r.agent), failed = rs.some(r => r.state === 'error');
    $('activity-button').hidden = !rs.length || phone();
    const tone = rs.some(r => attention(r) === 'amber') ? 'amber' : failed ? 'red' : 'green';
    $('chip-face').className = `chip-face ${tone}`;
    proposed($('activity-button'), android() || failed);
    proposed($('activity-summary'));
    $('activity-summary').textContent = summary(rs);
    $('chip-icon').textContent = rs.some(r => r.agent) ? '✧' : '▸_';
    $('activity-button').setAttribute('aria-label', `${summary(rs)}; shows panes that need attention`);
  }
  function renderActivity() {
    const rs = attentionRecords();
    // Channel loss never creates attention. An already-present row may remain
    // as historical evidence until this popover is dismissed.
    if (historicalRow && $('scenario').value === 'offline') rs.push(record('claude'));
    proposed($('activity-title')); proposed($('activity-caption'));
    proposed($('activity'), android()); $('activity-rows').replaceChildren();
    if (!rs.length) $('activity-rows').append(element('div', 'caught-up', 'all caught up'));
    rs.forEach(r => {
      const tone = attention(r), unavailable = r.state === 'unavailable';
      const row = proposed(element('div', 'activity-row'), !r.agent || r.state === 'error');
      if (r.key === 'claude') row.dataset.claude = 'true';
      const body = action('record-body', `${r.title || r.app}, ${r.app} ${r.label}, ${location(r)}`, () => r.agent ? openAgentCenter(r.key) : visit(r.key));
      const icon = element('span', 'record-icon');
      if (unavailable || r.state === 'blocked') icon.textContent = '◉!';
      else icon.append(element('span', 'circle-icon', r.state === 'error' ? '×' : '✓'));
      icon.setAttribute('aria-hidden', 'true');
      const copy = element('span', 'record-copy'); copy.append(recordTitle(r));
      const state = element('span', 'record-state');
      state.append(element('span', '', r.app), element('span', tone || 'dim', unavailable ? 'needs approval · 2 min ago' : r.label));
      copy.append(state);
      if (!unavailable) copy.append(proposed(element('span', 'record-message', r.message)));
      copy.append(element('span', 'record-location', location(r))); body.append(icon, copy); row.append(body);
      if (unavailable) row.append(element('span', 'pane-unavailable', 'pane unavailable'));
      else {
        const open = action('open-button', `Open ${r.title || r.app} on ${r.session}`, () => visit(r.key));
        open.append(element('span', 'open-face', '▸_ open pane')); row.append(open);
      }
      $('activity-rows').append(row);
    });
  }
  function recordTitle(r) {
    const title = element('span', 'record-title');
    if (r.agent) title.append(proposed(sparkle(r, attention(r), 'record-sparkle')), ' ');
    title.append(r.title || r.app);
    return title;
  }
  // Every record in this session, not only attention: working progress, ready
  // programs and already-checked results live here, behind the host pill.
  function programRows(target) {
    target.replaceChildren();
    const rs = sessionWindows().filter(r => r.state);
    if (!rs.length) { target.append(element('div', 'program-empty', 'no program status reported')); return; }
    rs.forEach(r => {
      const tone = attention(r), unavailable = r.state === 'unavailable';
      const row = element('div', 'program-row');
      const copy = element('div', 'program-copy');
      copy.append(recordTitle(r));
      const state = element('span', 'record-state');
      const word = unavailable ? 'status unavailable' : `${r.label}${r.seen && ['done', 'error'].includes(r.state) ? ' · checked' : ''}${r.progress !== undefined ? ` · ${r.progress}%` : ''}`;
      state.append(element('span', '', r.app), element('span', tone || 'dim', word));
      copy.append(state);
      if (r.progress !== undefined) {
        const bar = element('div', 'program-progress'); bar.setAttribute('role', 'progressbar');
        bar.setAttribute('aria-label', `${r.app} progress`); bar.setAttribute('aria-valuenow', r.progress);
        const fill = element('span'); fill.style.width = `${r.progress}%`; bar.append(fill); copy.append(bar);
      }
      copy.append(element('span', unavailable ? 'program-message historical-message' : 'program-message', unavailable ? `last report: ${r.message}` : r.message));
      copy.append(element('span', 'record-location', location(r)));
      row.append(copy);
      if (unavailable) row.append(element('span', 'pane-unavailable', 'pane unavailable'));
      else {
        const open = action('open-button', `Open ${r.title || r.app} on ${r.session}`, () => visit(r.key));
        open.append(element('span', 'open-face', '▸_ open pane')); row.append(open);
      }
      target.append(row);
    });
  }
  function renderPrograms() {
    const t = $('transport').value;
    const lines = [['transport', t === 'ssh' ? 'ssh' : t === 'ssh-tmux' ? 'ssh · tmux control mode' : 'mosh · tmux side channel'], ['state', $('scenario').value === 'offline' ? 'tmux status channel lost · reconnecting' : 'connected'], ['latency', '12 ms']];
    $('status-connection').replaceChildren(...lines.flatMap(([k, v]) => [element('span', '', k), element('span', '', v)]));
    proposed($('status-programs'));
    programRows($('program-rows'));
  }
  function anchorStatus() {
    const deviceRect = $('device').getBoundingClientRect(), pill = $('session-picker-button').getBoundingClientRect();
    const scale = deviceRect.width / $('device').offsetWidth;
    $('status-popover').style.left = `${Math.max(14, (pill.left - deviceRect.left) / scale)}px`;
  }
  function renderAgents() {
    const rs = allRecords().filter(r => r.agent);
    const groups = [
      ['needs you', rs.filter(r => r.state === 'blocked')],
      ['failed', rs.filter(r => attention(r) === 'red')],
      ['working', rs.filter(r => r.state === 'working')],
      ['finished', rs.filter(r => attention(r) === 'green')],
      ['recent', rs.filter(r => !attention(r) && r.state !== 'working')]
    ];
    $('thread-groups').replaceChildren();
    groups.forEach(([title, rows]) => {
      if (!rows.length) return;
      const group = proposed(element('div', 'thread-group'), title === 'failed');
      group.append(element('div', 'kicker', title));
      rows.forEach(r => {
        const row = action(`thread-row ${thread === r.key ? 'selected' : ''}`, `${r.title}, ${r.label}`, () => openAgentCenter(r.key));
        const tone = r.state === 'blocked' ? 'amber' : r.state === 'error' ? 'red' : ['working', 'done'].includes(r.state) ? 'green' : '';
        const heading = element('span', 'thread-heading');
        const dot = proposed(element('span', `thread-dot ${tone} ${r.state === 'working' ? 'working' : ''}`), tone === 'red');
        dot.setAttribute('aria-hidden', 'true'); heading.append(dot, element('span', '', r.title));
        row.append(heading, element('span', 'thread-identity', `${r.app} · tessera · main`)); group.append(row);
      });
      $('thread-groups').append(group);
    });
    if (raw() && thread === 'codex') thread = 'claude';
    const r = record(thread), claude = thread === 'claude';
    $('conversation-title').textContent = r.title;
    $('conversation-meta').textContent = `${r.app} · ${location(r)}`;
    const tone = r.state === 'blocked' ? 'amber' : r.state === 'error' ? 'red' : ['done', 'working'].includes(r.state) ? 'green' : 'dim';
    const status = proposed(element('span', tone, `${r.label}${r.progress !== undefined ? ` · ${r.progress}%` : ''}`), r.state === 'error' || r.progress !== undefined);
    const message = element('p', r.state === 'unavailable' ? 'dim historical-message' : '', r.message);
    proposed(message, r.state !== 'unavailable'); $('conversation-status').replaceChildren(status, message);
    $('conversation-pane').disabled = r.state === 'unavailable';
    $('conversation-pane').setAttribute('aria-label', `Open ${r.title} on ${r.session}`);
    $('user-message').textContent = claude ? 'Please fix the session restore path and check the affected tests.' : 'Review transport test coverage for reconnects.';
    $('agent-message').textContent = claude ? 'The launch path is updated. I’m checking the affected tests before handing it back.' : 'I’m reviewing the reconnect tests and following their transport state transitions.';
    $('tool-summary').textContent = claude ? 'edited  SessionRestore.swift\nqueued  swift test --package-path Packages/TesseraCore' : 'read  RealHostTransportIntegrationTests.swift\nread  reconnect coverage';
    $('conversation-hint').hidden = r.state !== 'blocked';
    $('agents-view').classList.toggle('show-thread', threadDetail);
  }
  function anchorPopover() {
    if (overlay !== 'activity') return;
    const deviceRect = $('device').getBoundingClientRect(), chipRect = $('activity-button').getBoundingClientRect();
    const scale = deviceRect.width / $('device').offsetWidth;
    const center = (chipRect.left + chipRect.width / 2 - deviceRect.left) / scale;
    const left = Math.max(14, Math.min(center - 190, $('device').offsetWidth - 394));
    $('activity').style.left = `${left}px`; $('activity').style.right = 'auto';
    $('activity').style.setProperty('--arrow-left', `${Math.max(16, Math.min(360, center - left))}px`);
  }
  function fitDevice() {
    const w = phone() ? 402 : 1194, h = phone() ? 844 : 834;
    const available = Math.max(1, $('stage').clientWidth - (window.innerWidth <= 460 ? 16 : 24));
    const scale = Math.min(1, available / w);
    $('device-viewport').style.width = `${w * scale}px`;
    $('device-viewport').style.height = `${h * scale}px`;
    $('device').style.transform = `scale(${scale})`; anchorPopover();
  }
  function render() {
    document.body.dataset.theme = $('appearance').value;
    document.body.dataset.layout = $('layout').value;
    document.body.dataset.platform = $('platform').value;
    document.body.classList.toggle('highlight-proposed', $('highlight').checked);
    const keyboard = phone() && $('keyboard').checked;
    document.body.classList.toggle('keyboard-visible', keyboard); $('mock-keyboard').hidden = !keyboard;
    $('keyboard').disabled = !phone();
    if (!agentCenter()) {
      if (view === 'agents') view = 'terminal';
      rootSegment = 'sessions';
    }
    $('sidebar-agents').hidden = !agentCenter();
    $('segment-control').hidden = !agentCenter();
    $('activity-agent-center').hidden = !agentCenter();
    $('sidebar').hidden = !sidebarShown || phone();
    $('sidebar-toggle').setAttribute('aria-expanded', String(sidebarShown));
    $('sidebar-toggle').setAttribute('aria-label', sidebarShown ? 'Hide sidebar' : 'Show sidebar');
    $('agents-view').classList.toggle('with-sidebar', sidebarShown && !phone());
    $('terminal-view').hidden = view !== 'terminal';
    $('root-view').hidden = view !== 'root';
    $('root-sessions').hidden = rootSegment !== 'sessions';
    $('segment-sessions').setAttribute('aria-pressed', String(rootSegment === 'sessions'));
    $('segment-agents').setAttribute('aria-pressed', String(rootSegment === 'agents'));
    const agentsVisible = view === 'agents' || (view === 'root' && rootSegment === 'agents');
    // One Agent Center surface, shared by tablet navigation and the phone segment.
    if (phone()) $('root-agent-slot').append($('agents-view'));
    else document.querySelector('.app-content').append($('agents-view'));
    $('agents-view').hidden = !agentsVisible;
    const r = record(selectedKey());
    $('connection-label').textContent = raw() && !phone() ? 'dev@devbox:22' : session;
    $('session-picker-button').classList.toggle('raw', raw()); $('tmux-tag').hidden = raw();
    $('terminal-output').textContent = r.terminal;
    $('terminal-location').textContent = r.state ? location(r) : `${session} · window ${r.number} “${r.window}”`;
    $('terminal-status').textContent = r.state === 'unavailable' ? 'needs approval · 2 min ago' : r.label || 'connected';
    $('transport-label').textContent = $('transport').selectedOptions[0].textContent;
    $('session-picker-button').setAttribute('aria-label', phone() ? 'Show sessions and windows' : 'Connection status');
    renderSessions(); renderWindows(); renderChip(); renderActivity(); renderAgents();
    renderPrograms(); renderPalette();
    fitDevice();
  }
  function showUtility(title, copy) {
    $('utility-title').textContent = title; $('utility-copy').textContent = copy;
    openOverlay('utility-panel', document.activeElement); feedback(`opened ${title} preview`);
  }
  for (const id of ['appearance', 'platform', 'highlight', 'keyboard']) $(id).addEventListener('change', render);
  $('layout').addEventListener('change', () => {
    closePanels(false);
    if (!phone() && view === 'root') view = rootSegment === 'agents' ? 'agents' : 'terminal';
    if (phone() && view === 'agents') { view = 'root'; rootSegment = 'agents'; }
    render(); feedback(phone() ? 'switched to iPhone preview' : 'switched to iPad preview');
  });
  $('scenario').addEventListener('change', () => {
    historicalRow = overlay === 'activity' && $('scenario').value === 'offline' && Boolean($('activity-rows').querySelector('[data-claude]'));
    // The previous DOM row is used only to decide whether loss retains history.
    seen = false; render(); feedback('new Claude report; focus stays in the same pane');
  });
  $('programs').addEventListener('change', () => { render(); feedback($('programs').value === 'hidden' ? 'generic program reports hidden' : 'generic program reports shown'); });
  $('agentcenter').addEventListener('change', () => {
    closePanels(false); render();
    feedback(agentCenter() ? 'agent center on; verified agents use the agent cues' : 'agent center off; Claude and Codex reports appear as generic programs');
  });
  $('transport').addEventListener('change', () => {
    session = 'devbox'; closePanels(false); render(); feedback('changed the transport sample');
  });
  $('sidebar-toggle').addEventListener('click', () => { sidebarShown = !sidebarShown; render(); feedback(sidebarShown ? 'sidebar shown' : 'sidebar hidden'); });
  $('sidebar-close').addEventListener('click', () => { sidebarShown = false; render(); $('sidebar-toggle').focus(); feedback('sidebar hidden'); });
  $('activity-button').addEventListener('click', () => openOverlay('activity', $('activity-button')));
  $('session-picker-button').addEventListener('click', () => openOverlay(phone() ? 'session-picker' : 'status-popover', $('session-picker-button')));
  $('backdrop').addEventListener('click', () => { closePanels(); feedback('closed the overlay'); });
  $('close-utility').addEventListener('click', () => closePanels());
  $('session-back').addEventListener('click', () => { view = 'root'; rootSegment = 'sessions'; closePanels(false); render(); feedback('back to sessions; sessions keep running'); });
  $('segment-sessions').addEventListener('click', () => { rootSegment = 'sessions'; render(); feedback('viewing sessions'); });
  $('root-sessions-tab').addEventListener('click', () => { rootSegment = 'sessions'; render(); });
  $('segment-agents').addEventListener('click', () => openAgentCenter());
  $('sidebar-agents').addEventListener('click', () => openAgentCenter());
  $('activity-agent-center').addEventListener('click', () => openAgentCenter());
  $('agents-back').addEventListener('click', () => { view = phone() ? 'root' : 'terminal'; rootSegment = 'sessions'; render(); feedback('returned to sessions'); });
  $('back-to-threads').addEventListener('click', () => { threadDetail = false; render(); feedback('viewing agent threads'); });
  $('conversation-pane').addEventListener('click', () => visit(thread));
  $('find-button').addEventListener('click', () => showUtility('find in terminal', 'search terminal scrollback'));
  $('files-button').addEventListener('click', () => showUtility('files', 'devbox · /home/dev/tessera'));
  $('home-button').addEventListener('click', () => showUtility('hosts', 'devbox · staging'));
  $('new-window').addEventListener('click', () => showUtility('new window', 'new tmux window'));
  $('disconnect-button').addEventListener('click', () => showUtility('disconnect', `disconnect ${session}?`));
  document.querySelectorAll('[data-utility]').forEach(node => node.addEventListener('click', () => showUtility(node.dataset.utility, node.dataset.utility)));
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' && overlay) { e.preventDefault(); closePanels(); feedback('closed the overlay'); }
    if (e.key === 'Tab' && overlay) {
      const buttons = Array.from($(overlay).querySelectorAll('button:not(:disabled)'));
      const first = buttons[0], last = buttons[buttons.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last?.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first?.focus(); }
    }
  });
  window.addEventListener('resize', fitDevice);
  render();
})();
