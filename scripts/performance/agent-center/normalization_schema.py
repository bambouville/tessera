"""Independent, content-free validation of the native projection vocabulary.

This is not a second renderer. It rejects malformed known fields and unknown
output discriminants before permissive client defaults can hide them.
"""
import collections
import math


RECORD_TYPES = frozenset(('message', 'ai-title', 'system', 'permission-mode', 'mode',
    'cost-state', 'queue-operation', 'session_meta', 'turn_context', 'metadata', 'completion'))
BLOCK_FIELDS = {
    'text': ('text',), 'thinking': ('text',), 'compact-summary': ('text',),
    'system-event': ('text',), 'tool_call': ('name', 'preview'),
    'tool_result': ('preview',), 'attachment': ('name', 'mediaType'), 'edit': ('path', 'diff'),
}

CLAUDE_BOOKKEEPING = {
    'file-history-snapshot': {'messageId': 's', 'snapshot': 'o', 'isSnapshotUpdate': 'b'},
    'file-history-delta': {'messageId': 's', 'snapshotMessageId': 's', 'trackingPath': 's', 'backup': 'o', 'timestamp': 's'},
    'last-prompt': {'leafUuid': 's', 'sessionId': 's', 'lastPrompt': 'optional-string'},
    'atis-latch': {'atis': 's', 'sessionId': 's'},
    'bridge-session': {'sessionId': 's', 'bridgeSessionId': 's', 'lastSequenceNum': 'n', 'ownerAccountUuid': 's', 'ownerOrganizationUuid': 's'},
    'relocated': {'sessionId': 's', 'relocatedCwd': 's'},
    'worktree-state': {'sessionId': 's', 'worktreeSession': '?'},
    'pr-link': {'sessionId': 's', 'prNumber': 'n', 'prUrl': 's', 'prRepository': 's', 'timestamp': 's'},
    'fork-context-ref': {'agentId': 's', 'parentSessionId': 's', 'parentLastUuid': 's', 'contextLength': 'n'},
}

CODEX_AUXILIARY = frozenset(('task_started', 'turn_started', 'turn_aborted', 'thread_settings_applied',
    'thread_goal_updated', 'world_state', 'inter_agent_communication_metadata', 'token_usage_record'))


def codex_auxiliary_issues(source, kind):
    """Independent consumed-field contract, not permission to hide new fields.

    protocol.rs bb1af235ea supplies the lifecycle/resume contracts. The removed
    historical token_usage_record is pinned by the private historical inventory,
    as are the thread_settings arrays codex-cli 0.156 writes on every resume
    (runtime_workspace_roots, disabled_plugin_ids), absent from that checkout.
    Arbitrary world-state data and permission-profile data are not messages.
    """
    issues = collections.Counter()
    def shape(value, required, optional=None):
        optional = optional or {}
        if not isinstance(value, dict): issues['source_invalid_auxiliary_object'] += 1; return
        for field in required:
            if field not in value: issues['source_missing_auxiliary_field'] += 1
        for field, item in value.items():
            tag = required.get(field, optional.get(field))
            if tag is None: issues['source_unknown_auxiliary_field'] += 1; continue
            if item is None and field in optional: continue
            valid = (tag == 'any' or tag == 'str' and isinstance(item, str) or tag == 'object' and isinstance(item, dict)
                     or tag == 'array' and isinstance(item, list)
                     or tag == 'bool' and type(item) is bool or tag == 'policy' and isinstance(item, (str, dict))
                     or tag == 'int' and type(item) is int and -(2**63) <= item < 2**63
                     or tag == 'uint' and type(item) is int and 0 <= item < 2**64)
            if not valid: issues['source_invalid_auxiliary_field'] += 1
    shape(source, dict(type='str', payload='object'), dict(ordinal='uint', timestamp='str', isSidechain='bool', isSubagent='bool'))
    payload = source.get('payload')
    if not isinstance(payload, dict): return dict(issues)
    event = kind in ('task_started', 'turn_started', 'turn_aborted', 'thread_settings_applied', 'thread_goal_updated')
    if source.get('type') != ('event_msg' if event else kind) or event and payload.get('type') != kind:
        issues['source_invalid_auxiliary_namespace'] += 1
    if kind in ('task_started', 'turn_started'):
        shape(payload, dict(type='str', turn_id='str'), dict(started_at='int', trace_id='str', model_context_window='int', collaboration_mode_kind='str'))
    elif kind == 'turn_aborted':
        shape(payload, dict(type='str', reason='str'), dict(turn_id='str', started_at='int', completed_at='int', duration_ms='int'))
        if payload.get('reason') not in ('interrupted', 'replaced', 'review_ended', 'budget_limited'): issues['source_unknown_abort_reason'] += 1
    elif kind == 'thread_settings_applied':
        shape(payload, dict(type='str', thread_settings='object'), dict(thread_id='str'))
        shape(payload.get('thread_settings'), dict(model='str', cwd='str', model_provider_id='str', approval_policy='policy',
            approvals_reviewer='str', permission_profile='object', collaboration_mode='object'),
            dict(personality='str', reasoning_effort='str', service_tier='str', reasoning_summary='str', active_permission_profile='object',
                 runtime_workspace_roots='array', disabled_plugin_ids='array'))
    elif kind == 'world_state': shape(payload, dict(full='bool', state='any'))
    elif kind == 'inter_agent_communication_metadata': shape(payload, dict(trigger_turn='bool'))
    elif kind == 'token_usage_record':
        shape(payload, dict(response_id='str', root_turn_id='str', session_id='str', thread_id='str', turn_id='str',
                            usage='object', turn_token_usage='object', thread_token_usage='object'))
        for family in ('usage', 'turn_token_usage', 'thread_token_usage'):
            shape(payload.get(family), dict.fromkeys(('input_tokens', 'cached_input_tokens', 'cache_write_input_tokens',
                'output_tokens', 'reasoning_output_tokens', 'total_tokens'), 'int'))
    elif kind == 'thread_goal_updated':
        shape(payload, dict(type='str', threadId='str', goal='object'), dict(turnId='str'))
        goal = payload.get('goal')
        shape(goal, dict(threadId='str', objective='str', status='str', tokensUsed='int', timeUsedSeconds='int',
                         createdAt='int', updatedAt='int'), dict(tokenBudget='int'))
        if isinstance(goal, dict) and goal.get('status') not in ('active', 'paused', 'blocked', 'usageLimited', 'budgetLimited', 'complete'):
            issues['source_unknown_goal_status'] += 1
    return dict(issues)


def bookkeeping_issues(source):
    schema = CLAUDE_BOOKKEEPING[source['type']]
    issues = collections.Counter()
    for key, kind in schema.items():
        if key not in source:
            if kind != 'optional-string': issues['source_missing_bookkeeping_field'] += 1
            continue
        value = source[key]
        valid = (isinstance(value, str) if kind in ('s', 'optional-string') else isinstance(value, dict) if kind == 'o'
                 else value is None or isinstance(value, dict) if kind == '?' else type(value) is bool if kind == 'b'
                 else type(value) is int and 0 <= value <= 2**64 - 1)
        if not valid: issues['source_invalid_bookkeeping_field'] += 1
    if source.keys() - schema.keys() - {'type'}:
        issues['source_unknown_bookkeeping_field'] += 1
    return dict(issues)


def output_issues(record):
    issues = collections.Counter()
    if not isinstance(record, dict): return {'output_non_object': 1}
    kind = record.get('type')
    if not isinstance(kind, str) or kind not in RECORD_TYPES:
        issues['output_unknown_record_type'] += 1
    if kind == 'message':
        if record.get('role') not in ('user', 'assistant', 'tool', 'system', 'developer'):
            issues['output_invalid_role'] += 1
        blocks = record.get('blocks')
        if not isinstance(blocks, list):
            issues['output_invalid_blocks'] += 1
        else:
            for block in blocks:
                if not isinstance(block, dict):
                    issues['output_non_object_block'] += 1; continue
                block_type = block.get('type')
                if not isinstance(block_type, str) or block_type not in BLOCK_FIELDS:
                    issues['output_unknown_block_type'] += 1; continue
                for field in BLOCK_FIELDS[block_type]:
                    if not isinstance(block.get(field), str): issues['output_invalid_block_field/' + field] += 1
                if 'toolCallID' in block and not isinstance(block['toolCallID'], str): issues['output_invalid_tool_id'] += 1
                if 'truncated' in block and type(block['truncated']) is not bool: issues['output_invalid_truncation'] += 1
    for field in ('model', 'branch', 'project', 'permissionMode', 'timestamp', 'sessionID', 'turnID', 'title', 'summary', 'text'):
        if field in record and not isinstance(record[field], str): issues['output_invalid_field/' + field] += 1
    for field in ('used_tokens', 'max_tokens', 'context_percent', 'totalCostUSD', 'totalDuration', 'totalLinesAdded', 'totalLinesRemoved', 'pending', 'count', 'unparsedContentCount'):
        if field in record:
            value = record[field]
            if type(value) not in (int, float) or not math.isfinite(value): issues['output_invalid_number/' + field] += 1
    for field in ('isMeta', 'isCompactSummary', 'isSidechain', 'truncated'):
        if field in record and type(record[field]) is not bool: issues['output_invalid_flag/' + field] += 1
    return dict(issues)


def source_shape_issues(source, provider):
    issues = collections.Counter()
    if not isinstance(source, dict): return {'source_non_object': 1}
    if provider == 'claude' and isinstance(source.get('type'), str) and source['type'] in CLAUDE_BOOKKEEPING:
        return bookkeeping_issues(source)
    if provider == 'codex':
        kind = source.get('payload', {}).get('type') if source.get('type') == 'event_msg' and isinstance(source.get('payload'), dict) else source.get('type')
        if isinstance(kind, str) and kind in CODEX_AUXILIARY: return codex_auxiliary_issues(source, kind)
        if source.get('type') == 'event_msg' and kind == 'item_completed':
            payload = source['payload']
            for key in ('thread_id', 'turn_id'):
                value = payload.get(key)
                if not isinstance(value, str) or not 0 < len(value.encode('utf-8')) <= 256:
                    issues['source_invalid_completed_identity'] += 1
            for key in ('started_at_ms', 'completed_at_ms'):
                if key not in payload or key == 'started_at_ms' and payload[key] is None: continue
                if type(payload[key]) is not int or not -(2**63) <= payload[key] < 2**63:
                    issues['source_invalid_completed_timestamp'] += 1
            if source.get('ordinal') is not None and (type(source['ordinal']) is not int or not 0 <= source['ordinal'] < 2**64):
                issues['source_invalid_completed_ordinal'] += 1
            if not isinstance(payload.get('item'), dict): issues['source_invalid_completed_item'] += 1
            return dict(issues)

    def first(value, *keys):
        return next((value[key] for key in keys if value.get(key) is not None), None)

    def content(value, depth=0):
        if depth > 16: issues['source_content_depth'] += 1; return
        if value is None or isinstance(value, str): return
        if isinstance(value, list):
            for item in value: content(item, depth + 1)
            return
        if not isinstance(value, dict): issues['source_invalid_content_shape'] += 1; return
        kind = value.get('type')
        if kind in ('text', 'input_text', 'output_text', 'summary_text', 'reasoning_text', 'connector_text'):
            if not isinstance(value.get('text'), str): issues['source_invalid_text_field'] += 1
        elif kind in ('tool_result', 'function_call_output', 'custom_tool_call_output'):
            content(first(value, 'content', 'output'), depth + 1)
        elif kind == 'thinking':
            if not isinstance(first(value, 'thinking', 'text'), str): issues['source_invalid_thinking_field'] += 1
        elif kind == 'advisor_tool_result':
            result = value.get('content')
            if not isinstance(result, dict): issues['source_invalid_advisor_result'] += 1
            elif result.get('type') == 'advisor_result' and not isinstance(result.get('text'), str):
                issues['source_invalid_advisor_text'] += 1
        elif kind is None:
            issues['source_missing_content_type'] += 1
        # Unknown discriminants are independently counted by the native
        # unknown marker/count. Never recurse through arbitrary tool input.

    if provider == 'claude' and source.get('type') in ('user', 'assistant', 'system'):
        message = source.get('message')
        message = message if isinstance(message, dict) else {}
        body = first(message, 'content') if first(message, 'content') is not None else first(source, 'content', 'text')
        if source['type'] in ('user', 'assistant') and body is None: issues['source_missing_message_content'] += 1
        if 'role' in message and not isinstance(message['role'], str): issues['source_invalid_role_shape'] += 1
        content(body)
    elif provider == 'codex' and source.get('type') == 'response_item':
        payload = source.get('payload')
        if not isinstance(payload, dict):
            content = None
            return {'source_invalid_payload': 1}
        if payload.get('type') in ('message', 'agent_message', 'user_message'):
            body = first(payload, 'content', 'message', 'text')
            annotation = payload.get('internal_chat_message_metadata_passthrough')
            if payload.get('role') == 'user' and annotation is not None and not isinstance(annotation, dict):
                issues['source_invalid_annotation_container'] += 1
            elif payload.get('role') == 'user' and isinstance(annotation, dict) and 'content_item_kinds' in annotation:
                kinds = annotation['content_item_kinds']
                if not isinstance(kinds, list) or not isinstance(body, list) or len(kinds) != len(body) or any(not isinstance(k, str) for k in kinds):
                    issues['source_invalid_content_item_kinds'] += 1
            content(body)
        elif payload.get('type') in ('function_call_output', 'custom_tool_call_output'):
            content(first(payload, 'content', 'output'))
        elif payload.get('type') == 'reasoning':
            content(first(payload, 'thinking', 'text', 'summary'))
            content(payload.get('summary')); content(payload.get('content'))
    content = None  # Release the recursive closure without waiting for cyclic GC.
    return dict(issues)
