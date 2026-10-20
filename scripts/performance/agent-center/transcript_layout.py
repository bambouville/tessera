"""Finite fixture layout helpers; never infer provider identity from content."""
from pathlib import Path
import os
import re


def default_claude_projects_root():
    return Path(os.environ.get('CLAUDE_CONFIG_DIR') or Path.home() / '.claude') / 'projects'


def claude_relative(original, projects_root):
    path = Path(original)
    root = Path(projects_root)
    if not path.is_absolute() or not root.is_absolute():
        raise ValueError('explicit absolute provider root required')
    relative = path.relative_to(root)
    if any(part in ('.', '..') for part in relative.parts):
        raise ValueError('invalid provider-relative path')
    return relative


def claude_layout(relative, valid=lambda value: re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', value)):
    parts = relative.parts
    if len(parts) < 2 or not relative.name.endswith('.jsonl'):
        return 'non_session_jsonl'
    if len(parts) == 2 and valid(relative.stem):
        return 'main_session'
    if len(parts) >= 4 and valid(parts[1]) and parts[2] == 'subagents' and relative.name.startswith('agent-'):
        return 'subagent_session'
    return 'non_session_jsonl'


def candidate_is_session(entry, claude_projects_root):
    return entry['provider'] != 'claude' or claude_layout(claude_relative(
        entry.get('original_path', entry['path']), entry.get('source_root', claude_projects_root))) != 'non_session_jsonl'
