#!/usr/bin/env python3
"""Package completed, connection-free native window gates for one visual review.

iPad XCUIScreenshot can crop landscape content into portrait pixels. Use the
original simctl recording at named attachment timestamps, preserving the
recording and timestamp provenance rather than presenting that crop as UI.
"""
import argparse
from datetime import datetime
import json
import re
from pathlib import Path
import shutil
import subprocess


def landscape_video_filter(video):
    metadata = json.loads(subprocess.check_output([
        'ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
        'stream=width,height:stream_side_data=rotation', '-of', 'json', str(video)]))
    stream = metadata['streams'][0]
    width, height = stream['width'], stream['height']
    if width <= 0 or height <= 0:
        raise ValueError('Cannot read video dimensions')
    rotation = next((side['rotation'] for side in stream.get('side_data_list', [])
                     if 'rotation' in side), 0)
    if float(rotation) % 360 in (90, 270):
        width, height = height, width
    return 'transpose=cclock,' if height > width else ''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phone-attachments', required=True, type=Path)
    parser.add_argument('--ipad-attachments', required=True, type=Path)
    parser.add_argument('--ipad-video', required=True, type=Path)
    parser.add_argument('--phone-test-log', required=True, type=Path)
    parser.add_argument('--ipad-test-log', required=True, type=Path)
    parser.add_argument('--android-phone', required=True, type=Path)
    parser.add_argument('--android-tablet', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--chat', action='store_true', help='Package chat-follow rather than history-window captures')
    parser.add_argument('--compose-artifacts', type=Path, help='Include the completed Android composer/receipt regression captures')
    args = parser.parse_args()
    for path in (args.phone_test_log, args.ipad_test_log):
        log = path.read_text()
        if '** TEST SUCCEEDED **' not in log or (not args.chat and 'revisionSplits=1' not in log):
            raise ValueError('native UI test did not pass its split gate')
    for path in (args.android_phone, args.android_tablet):
        if (not re.search(r'\bOK \([1-9][0-9]* tests?\)', (path / 'instrumentation.log').read_text()) or
            (not args.chat and 'lane=revisions partitionCount=2' not in (path / 'device.log').read_text()) or
            'result=0' not in (path / 'cleanup.txt').read_text()):
            raise ValueError('Android split gate or owned-device cleanup did not pass')
    if args.output.exists():
        raise ValueError('output must be new; do not overwrite prior evidence')
    root = args.output / 'visual' / 'cases'
    stages = dict(deep='deep-history', held='live-head-does-not-move-history',
                  forward='forward-history', latest='returned-to-latest')
    if args.chat:
        stages = {stage: stage for stage in ['initial-bottom', 'same-record-growth', 'detached-before', 'detached-growth', 'returned-to-latest', 'coalesced-tools']}
    metadata = json.loads(subprocess.check_output(['ffprobe', '-v', 'quiet', '-show_entries',
        'format_tags=creation_time', '-of', 'json', str(args.ipad_video)]))
    epoch = datetime.fromisoformat(metadata['format']['tags']['creation_time'].replace('Z', '+00:00')).timestamp()
    rotate = landscape_video_filter(args.ipad_video)
    frame_metadata = json.loads(subprocess.check_output(['ffprobe', '-v', 'quiet', '-select_streams', 'v:0',
        '-show_entries', 'frame=best_effort_timestamp_time', '-of', 'json', str(args.ipad_video)]))
    frame_times = [float(frame['best_effort_timestamp_time']) for frame in frame_metadata['frames']]
    for device, source in [('iphone', args.phone_attachments), ('ipad', args.ipad_attachments),
                           ('android-phone', args.android_phone), ('android-tablet', args.android_tablet)]:
        case_id = ('AG3-chat-follow-' if args.chat else 'AG3-resegmentation-') + device
        directory = root / case_id
        directory.mkdir(parents=True)
        provenance = []
        if device in ('iphone', 'ipad'):
            attachments = [item for test in json.loads((source / 'manifest.json').read_text())
                           for item in test.get('attachments', [])]
            for stage, name in stages.items():
                prefix = 'chat-' if args.chat else 'bounded-window-'
                matches = [item for item in attachments if item.get('suggestedHumanReadableName', '').startswith(prefix + name + '_')]
                if len(matches) != 1:
                    raise ValueError('missing or ambiguous named acceptance screenshot')
                item = matches[0]
                target = directory / (stage + '.png')
                if device == 'iphone':
                    shutil.copy2(source / item['exportedFileName'], target)
                else:
                    # simctl's creation_time is whole-second precision. A
                    # nominally timestamp-matched frame may therefore land
                    # after the next input gesture. Sample within the quiet
                    # pre-capture interval, allowing a full second of clock
                    # uncertainty plus 250 ms. Tests settle before baselines.
                    offset = item['timestamp'] - epoch - 1.25
                    if offset < 0:
                        raise ValueError('attachment predates recording')
                    # simctl emits variable-rate video: -ss chooses the NEXT
                    # encoded frame, possibly seconds later during teardown.
                    # The visible frame is the last one at or before the time.
                    candidates = [index for index, time in enumerate(frame_times) if time <= offset]
                    if not candidates:
                        raise ValueError('no video frame precedes the acceptance timestamp')
                    frame_index = candidates[-1]
                    subprocess.run(['ffmpeg', '-v', 'error', '-i', str(args.ipad_video),
                        '-frames:v', '1', '-vf', f'select=eq(n\\,{frame_index})' + (',' + rotate.rstrip(',') if rotate else ''), '-fps_mode', 'vfr', str(target)], check=True)
                    provenance.append(dict(stage=stage, video=str(args.ipad_video), offsetSeconds=offset,
                                           frameIndex=frame_index, framePresentationSeconds=frame_times[frame_index],
                                           attachmentTimestamp=item['timestamp'], timestampUncertaintySeconds=1,
                                           preCaptureMarginSeconds=1.25,
                                           rotation='counterclockwise90' if rotate else 'none'))
        else:
            android_stages = ['chat-' + stage for stage in stages] if args.chat else ['deep-history', 'history-with-live-head', 'history-with-resegmentation', 'forward-history', 'latest']
            for stage in android_stages:
                shutil.copy2(source / (stage + '.png'), directory / (stage + '.png'))
        definition = dict(id=case_id, title='Bounded retained-page resegmentation: ' + device, matrix_ids=['AG3'],
            invariants=[
                'Conversation text remains readable, with grouped tool results and explicit shortened-preview disclosures.',
                'Deep and held/resegmentation frames retain the same visible reading position as live head and segment identities change.',
                'Forward history reaches newer records; Return to Latest displays the latest range and removes its detached-history affordance.',
                'No empty transcript, overlapping message rows or corrupted conversation geometry appears.'
            ], capture_notes='Synthetic connection-free production native UI and shared reducer. Phones portrait; tablets landscape. '
                'iPad uses timestamp-matched original video frames because XCUIScreenshot crops landscape pixels. '
                'Ignore the existing debug harness shell/status-bar layout; grade conversation invariants. '
                'These are not SSH latency, private-corpus paint or physical-device memory measurements.',
            deterministic_precheck=dict(verdict='pass', details='Completed native tests assert deep and forward history, at most four viewport segments, '
                'a revision split, preserved visible anchor within three points/pixels, and Return to Latest. Owned devices were disposed.'))
        if args.chat:
            definition.update(title='Chat follow and deliberate history reading: ' + device,
                invariants=[
                    'Initial bootstrap, same-record growth, returned-to-latest and coalesced-tools frames show the end of the latest reply.',
                    'Detached-before and detached-growth frames retain the same earlier reading position and Return to Latest affordance; new output does not force the end into view.',
                    'Conversation remains readable without overlap or blank-content failures on phone and landscape tablet.',
                    'Tool groups remain present as appropriate for viewport position; Return to Latest disappears after resuming follow.'
                ], deterministic_precheck=dict(verdict='pass', details='Native tests verify initial tail, same-ID growth, detached anchor stability, explicit return and tool coalescing.'))
        (directory / 'case.json').write_text(json.dumps(definition, indent=2) + '\n')
        if provenance:
            (directory / 'video-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    if args.compose_artifacts:
        source = args.compose_artifacts
        if ('OK (28 tests)' not in (source / 'instrumentation.log').read_text() or
            'result=0' not in (source / 'cleanup.txt').read_text()):
            raise ValueError('Compose suite or disposable-device cleanup did not pass')
        case_id = 'AG3-android-composer-receipts'
        directory = root / case_id
        directory.mkdir()
        captures = list((source / 'compose-captures').glob('*.png'))
        if len(captures) != 11:
            raise ValueError('expected all eleven Compose regression captures')
        for capture in captures:
            shutil.copy2(capture, directory / capture.name)
        (directory / 'case.json').write_text(json.dumps(dict(id=case_id,
            title='Android composer, optimistic reply and history layout', matrix_ids=['AG3'],
            invariants=['Composer and outgoing reply remain readable without overlapping or clipping one another.',
                'Collapsed and expanded tool groups retain coherent conversation layout.',
                'History prepend preserves the visible message position; retry restores readable history.'],
            capture_notes='Synthetic production Compose fixtures on an owned Android emulator; orientation is visible in the captures. These are not private provider data. '
                'Pending-layout 0/1/2/3 are consecutive layout captures; the test also asserts composer resize/IME and receipt behavior.',
            deterministic_precheck=dict(verdict='pass', details='All 28 Compose tests pass with the generated shared-Core fixture; no skipped assumptions. Owned emulator removed.')), indent=2))
    subprocess.run(['python3', str(Path(__file__).with_name('finalize-visual-evidence.py')), str(args.output / 'visual')], check=True)


if __name__ == '__main__':
    main()
