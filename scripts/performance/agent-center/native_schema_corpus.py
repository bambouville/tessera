#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["jsonschema==4.25.1"]
# ///
"""Validate private native Codex items against a pinned generated official schema.

Run with uv run --script. No provider is launched. SQLite is opened read-only
and backed up to an owned private snapshot. This checks source field shapes,
not normalization equivalence. Reports never include validator messages,
instance paths, item values, or IDs (these may contain conversation content).
"""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import sys
from jsonschema.validators import validator_for


class ItemSchema:
    def __init__(self, schema):
        def local_only(value):
            if isinstance(value, dict):
                if '$ref' in value and not value['$ref'].startswith('#/'):
                    raise ValueError('nonlocalSchemaReference')
                for entry in value.values(): local_only(entry)
            elif isinstance(value, list):
                for entry in value: local_only(entry)
        local_only(schema)
        validator = validator_for(schema)
        self.validators = {}
        for index, branch in enumerate(schema['definitions']['v2']['ThreadItem']['oneOf']):
            tags = branch['properties']['type']['enum']
            if len(tags) != 1 or tags[0] in self.validators: raise ValueError('ambiguousItemDiscriminator')
            # Dispatch the disjoint tagged union, while preserving the complete
            # root for nested refs. No hand-written field-shape approximation.
            root = dict(schema, **{'$ref': f'#/definitions/v2/ThreadItem/oneOf/{index}'})
            self.validators[tags[0]] = validator(root)

    def issues(self, item):
        if not isinstance(item, dict): return {'sourceNonObject': 1}
        tag = item.get('type')
        if not isinstance(tag, str) or tag not in self.validators: return {'unknownSourceItemType': 1}
        counts = collections.Counter()
        for error in self.validators[tag].iter_errors(item):
            # Keywords are schema-owned, not provider/user-controlled paths.
            counts[str(error.validator)] += 1
        return dict(counts)


def self_test():
    schema = {'$schema': 'http://json-schema.org/draft-07/schema#', 'definitions': {'v2': {'ThreadItem': {'oneOf': [
        {'type': 'object', 'required': ['type', 'text'], 'properties': {
            'type': {'type': 'string', 'enum': ['agentMessage']}, 'text': {'type': 'string'}}}
    ]}}}}
    validator = ItemSchema(schema)
    assert validator.issues({'type': 'agentMessage', 'text': 'synthetic'}) == {}
    assert validator.issues({'type': 'agentMessage', 'text': 42}) == {'type': 1}
    assert validator.issues({'type': 'agentMessage'}) == {'required': 1}
    assert validator.issues({'type': 'future'}) == {'unknownSourceItemType': 1}
    schema['definitions']['remote'] = {'$ref': 'https://example.invalid/schema'}
    try: ItemSchema(schema)
    except ValueError: pass
    else: raise AssertionError('external schema reference accepted')
    print('Schema dispatch, malformed-known, unknown and offline-reference tests passed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--schema', type=Path, required=True)
    parser.add_argument('--snapshot', type=Path, required=True, help='Finite private thread_history_1.sqlite snapshot')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--fixtures', type=Path, help='Synthetic item/expected-block fixtures for types absent from the private corpus')
    args = parser.parse_args()
    destination = args.output.resolve()
    if any((parent / '.git').exists() for parent in [destination, *destination.parents]):
        parser.error('private output must be outside Git')
    os.umask(0o077); destination.mkdir(mode=0o700)
    schema_bytes = args.schema.read_bytes()
    (destination / 'measured-schema.json').write_bytes(schema_bytes)
    validator = ItemSchema(json.loads(schema_bytes))
    fixture_types = set()
    if args.fixtures:
        fixture_bytes = args.fixtures.read_bytes()
        (destination / 'measured-fixtures.json').write_bytes(fixture_bytes)
        for fixture in json.loads(fixture_bytes):
            item = fixture['item']
            if validator.issues(item): raise ValueError('invalidSyntheticSchemaFixture')
            fixture_types.add(item['type'])
    database_path = destination / 'measured-history.sqlite'
    source = sqlite3.connect(args.snapshot.resolve().as_uri() + '?mode=ro', uri=True)
    database = sqlite3.connect(database_path)
    try: source.backup(database)
    finally: source.close()
    maximum = 32 * 1024 * 1024
    records = failures = 0
    types = collections.Counter(); issues = collections.Counter()
    # SQLite performs the length check before handing a giant payload to Python.
    query = 'SELECT CASE WHEN length(CAST(item_json AS BLOB))<=? THEN item_json ELSE NULL END FROM thread_items ORDER BY thread_id,rollout_ordinal'
    try:
        for (raw,) in database.execute(query, (maximum,)):
            records += 1
            if raw is None: found = {'sourceItemBudgetExceeded': 1}
            else:
                try: item = json.loads(raw)
                except (ValueError, UnicodeError): found = {'sourceMalformedJSON': 1}
                else:
                    tag = item.get('type') if isinstance(item, dict) else None
                    types[tag if isinstance(tag, str) and tag in validator.validators else 'unknown'] += 1
                    found = validator.issues(item)
            issues.update(found); failures += bool(found)
    finally: database.close()
    report = dict(stage='native_source_schema_not_normalization_equivalence', records=records,
        failed_records=failures, issues=dict(issues), types=dict(types),
        schema_types_absent_from_corpus=sorted(set(validator.validators) - set(types)),
        validated_fixture_types=sorted(fixture_types),
        schema_types_without_source_examples=sorted(set(validator.validators) - set(types) - fixture_types),
        schema_sha256=hashlib.sha256(schema_bytes).hexdigest(),
        validator_version='jsonschema/4.25.1', max_item_bytes=maximum)
    (destination / 'content-free-results.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report))
    if failures or not records: raise SystemExit(1)


if __name__ == '__main__':
    if sys.argv[1:] == ['--self-test']: self_test()
    else: main()
