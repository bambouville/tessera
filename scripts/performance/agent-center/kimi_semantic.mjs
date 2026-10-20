#!/usr/bin/env node
// Private, content-free differential gate against Kimi's pinned official
// display-history reducer. No provider/plugin loading, credentials or network.
// Only upstream source and test-driver executables explicitly supplied below
// are executed. Upstream payloads remain in memory, never in result artifacts.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import crypto from 'node:crypto';
import os from 'node:os';
import {createRequire} from 'node:module';
import {spawnSync} from 'node:child_process';

const args = Object.fromEntries(process.argv.slice(2).reduce((rows, item, i, all) =>
  i % 2 ? rows : [...rows, [item.replace(/^--/, ''), all[i + 1]]], []));
for (const name of ['source', 'typescript', 'driver', 'normalizer', 'root']) if (!args[name]) throw new Error(`missing --${name}`);
const revision = spawnSync('git', ['-C', args.source, 'rev-parse', 'HEAD'], {encoding: 'utf8'});
if (revision.status !== 0 || revision.stdout.trim() !== '95478e8c7ba248fd2470d5bb151555ec7fedd19d') throw new Error('upstream revision mismatch');
if (spawnSync('git', ['-C', args.source, 'diff', '--quiet', 'HEAD', '--', 'packages/agent-core-v2/src', 'packages/agent-core-v2/docs/wire-manifest.d.ts']).status !== 0)
  throw new Error('upstream source is modified');
const ts = createRequire(import.meta.url)(path.resolve(args.typescript));
const base = path.join(args.source, 'packages/agent-core-v2/src');
const contextBase = 'agent/contextMemory/';
const allowed = new Set(['kosong/contract/message.ts', 'kosong/contract/tokens.ts',
  'features/reminder/systemReminder.ts', ...['contextTranscript.ts', 'loopEventFold.ts',
  'conversationTime.ts', 'vacuousContent.ts', 'compactionHandoff.ts', 'compaction-summary-prefix.md?raw'].map(n => contextBase + n)]);
const cache = new Map();
function load(name) {
  if (!allowed.has(name)) throw new Error('oracle import outside allowlist');
  if (cache.has(name)) return cache.get(name);
  if (name.endsWith('?raw')) return {__esModule: true, default: fs.readFileSync(path.join(base, name.slice(0, -4)), 'utf8')};
  let source = fs.readFileSync(path.join(base, name), 'utf8');
  // Extract exact upstream declarations to omit unrelated state registration
  // and Immer-bound model-context reducers. No display reducer is rewritten,
  // stubbed or reimplemented; these are its genuine runtime dependencies.
  const select = name.endsWith('/conversationTime.ts') ? new Set(['isUndoAnchorOrigin', 'isUndoAnchor', 'isPromptOwnedInjection']) :
    name.endsWith('/loopEventFold.ts') ? new Set(['TOOL_INTERRUPTED_ON_RESUME_OUTPUT', 'createLoopEventFold', 'createLoopEventFoldWithState', 'interruptedToolMessage']) : null;
  if (select) {
    const ast = ts.createSourceFile(name, source, ts.ScriptTarget.Latest, true);
    source = ast.statements.filter(node => {
      if (ts.isImportDeclaration(node)) return name.endsWith('/loopEventFold.ts') && node.moduleSpecifier.text !== 'immer';
      return (node.name && select.has(node.name.text)) || (ts.isVariableStatement(node) && node.declarationList.declarations.some(d => select.has(d.name.text)));
    }).map(node => node.getText(ast)).join('\n');
  }
  const module = {exports: {}}; cache.set(name, module.exports);
  const compiled = ts.transpileModule(source, {compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022}}).outputText;
  const require = request => {
    let resolved = request.startsWith('#/') ? request.slice(2) : path.posix.normalize(path.posix.join(path.posix.dirname(name), request));
    if (!resolved.endsWith('?raw')) resolved += '.ts';
    return load(resolved);
  };
  vm.runInNewContext('(function(require,module,exports){' + compiled + '\n})', {}, {timeout: 1000})(require, module, module.exports);
  return module.exports;
}
const {reduceContextTranscript} = load(contextBase + 'contextTranscript.ts');
function files(root) {
  const result = [];
  for (const entry of fs.readdirSync(root, {withFileTypes: true})) {
    const child = path.join(root, entry.name);
    if (entry.isDirectory()) result.push(...files(child));
    else if (entry.isFile() && entry.name === 'wire.jsonl') result.push(child);
  }
  return result;
}
const visible = message => message.role !== 'system' && !['injection', 'retry'].includes(message.origin?.kind) &&
  (message.origin?.kind !== 'system_trigger' || ['goal_continuation', 'subagent'].includes(message.origin.name));
const roleOf = message => message.origin?.kind === 'compaction_summary' ||
  (['skill_activation', 'plugin_command'].includes(message.origin?.kind) && message.origin.trigger !== 'user-slash') ? 'system' : message.role;
const tokens = message => {
  if (!visible(message)) return [];
  const role = roleOf(message);
  const content = message.content ?? [];
  if (role === 'tool') return [['result', message.toolCallId, content, message.isError === true]];
  return [...content.map(part => ['part', role, part]), ...(message.toolCalls ?? []).map(call => ['call', call.id, call.name, call.arguments ?? null])];
};
function selectedTokens(row, interrupted) {
  if (interrupted) return [['result', row.event.toolCallId, [{type: 'text', text: 'Tool execution was interrupted before its result was recorded. Do not assume the tool completed successfully.'}], true]];
  if (row.type === 'context.append_message') return tokens(row.message);
  if (row.type === 'context.apply_compaction') {
    const text = typeof row.summary === 'string' ? row.summary : typeof row.contextSummary === 'string' ? row.contextSummary :
      row.summary.content.filter(p => p.type === 'text').map(p => p.text).join('');
    return [['part', 'system', {type: 'text', text}]];
  }
  if (row.type !== 'context.append_loop_event') return [];
  const event = row.event;
  if (event.type === 'content.part') return [['part', 'assistant', event.part]];
  if (event.type === 'tool.call') return [['call', event.toolCallId, event.name, event.args === undefined ? null : JSON.stringify(event.args)]];
  if (event.type === 'tool.result') return [['result', event.toolCallId,
    typeof event.result.output === 'string' ? [{type: 'text', text: event.result.output}] : event.result.output, event.result.isError === true]];
  return [];
}
const digest = value => crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
let failures = 0, records = 0, unknown = 0, peakRSSBytes = 0, indexBytes = 0, selectedCount = 0;
const mismatches = [];
const paths = files(args.root).sort();
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'tessera-kimi-semantic-')); fs.chmodSync(scratch, 0o700);
let indexLatencyMS = 0, normalizationLatencyMS = 0;
try {
for (let number = 0; number < paths.length; number++) {
  const file = paths[number];
  const before = fs.statSync(file, {bigint: true});
  if (before.size > 64n * 1024n * 1024n) throw new Error('reference input memory budget exceeded');
  const raw = fs.readFileSync(file);
  const after = fs.statSync(file, {bigint: true});
  if (['dev', 'ino', 'size', 'mtimeNs', 'ctimeNs'].some(key => before[key] !== after[key])) throw new Error('reference snapshot changed');
  const snapshot = path.join(scratch, 'wire.jsonl'); fs.writeFileSync(snapshot, raw, {mode: 0o600});
  const rows = []; const offsets = new Map(); let offset = 0;
  for (const line of raw.toString('utf8').split(/(?<=\n)/)) {
    if (!line.endsWith('\n')) continue; // Only durable complete lines.
    const row = JSON.parse(line); rows.push(row); offsets.set(offset, row); offset += Buffer.byteLength(line);
  }
  records += rows.length;
  const normalizeStart = performance.now();
  const normalized = spawnSync(args.normalizer, ['kimi', snapshot], {encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 30000});
  normalizationLatencyMS = Math.max(normalizationLatencyMS, performance.now() - normalizeStart);
  if (normalized.status !== 0) { failures++; continue; }
  const normalizedRows = normalized.stdout.trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
  const completion = normalizedRows.pop();
  const starts = [...offsets.keys()];
  if (!completion || completion.complete !== true || completion.sourceEnd !== offset ||
      !Number.isSafeInteger(completion.peakRSSBytes) || completion.peakRSSBytes <= 0 ||
      normalizedRows.length !== starts.length || normalizedRows.some((row, i) =>
        row.start !== starts[i] || row.end !== (starts[i + 1] ?? offset) || !row.record ||
        !['message', 'system', 'metadata', 'status', 'ignored', 'unclassified'].includes(row.disposition))) {
    failures++; continue;
  }
  peakRSSBytes = Math.max(peakRSSBytes, completion.peakRSSBytes);
  for (const row of normalizedRows) {
    if (row.record?.type === 'unknown' || row.record?.unparsedContentCount > 0) unknown++;
  }
  const indexStart = performance.now();
  const native = spawnSync(args.driver, [snapshot], {encoding: 'utf8', maxBuffer: 4 * 1024 * 1024, timeout: 30000});
  indexLatencyMS = Math.max(indexLatencyMS, performance.now() - indexStart);
  if (native.status !== 0) { failures++; continue; }
  const index = JSON.parse(native.stdout); peakRSSBytes = Math.max(peakRSSBytes, index.peakRSSBytes); indexBytes = Math.max(indexBytes, index.indexBytes);
  const actual = index.selected.flatMap(row => selectedTokens(offsets.get(row.offset), row.interrupted));
  const expected = reduceContextTranscript(rows).entries.flatMap(tokens);
  selectedCount += actual.length;
  if (digest(actual) !== digest(expected)) {
    let first = 0; while (first < Math.min(actual.length, expected.length) && digest(actual[first]) === digest(expected[first])) first++;
    mismatches.push({fileOrdinal: number, expected: expected.length, actual: actual.length, first,
      expectedKind: expected[first]?.[0], actualKind: actual[first]?.[0]});
  }
}
} finally { fs.rmSync(scratch, {recursive: true}); }
console.log(JSON.stringify({upstream: revision.stdout.trim(), files: paths.length, records, selectedTokens: selectedCount,
  fileFailures: failures, unknownOrUnparsed: unknown, semanticMismatches: mismatches, peakRSSBytes, indexBytes,
  maximumIndexProcessMS: indexLatencyMS, maximumNormalizationProcessMS: normalizationLatencyMS,
  referenceProcessPeakRSSBytes: process.resourceUsage().maxRSS * 1024}));
if (!paths.length || failures || unknown || mismatches.length) process.exitCode = 1;
