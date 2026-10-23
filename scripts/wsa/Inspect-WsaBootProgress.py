#!/usr/bin/env python3
"""Read local WSA ETW/logcat/ANR evidence for an unfinished boot.

Reports selected diagnostic text only, without uploading logs or changing the
runtime. ETW line numbers refer to the original XML, including embedded CRs.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

NS = {'e': 'http://schemas.microsoft.com/win/2004/08/events/event'}


def source_info(path):
    data = path.read_bytes()
    return {'file': path.name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}


def xml_events(path):
    xml = path.read_bytes().decode('utf-8-sig')
    line, cursor = 1, 0
    for match in re.finditer(r'<Event\s[^>]*>.*?</Event>', xml, re.S):
        line += xml.count('\n', cursor, match.start())
        cursor = match.start()
        chunk = match.group()
        event = ET.fromstring(chunk)
        fields = {x.get('Name'): x.text or '' for x in event.findall('e:EventData//e:Data', NS)}
        task = event.findtext('e:RenderingInfo/e:Task', '', NS)
        time = event.find('e:System/e:TimeCreated', NS).get('SystemTime')
        text_start = chunk.find('<Data Name="text">')
        yield {'time': time, 'xmlEventLine': line,
               'xmlTextLine': line + chunk.count('\n', 0, text_start) if text_start >= 0 else None,
               'task': task, 'fields': fields}


def guest_record(event):
    return {'time': event['time'], 'xmlLine': event['xmlTextLine'], 'text': event['fields']['text'].strip()}


def matching_lines(path, pattern):
    return [{'line': index, 'text': text} for index, text in enumerate(path.read_text(encoding='utf-8', errors='replace').splitlines(), 1)
            if re.search(pattern, text)]


def analyze(capture, logcat=None, anr=None):
    guest = list(xml_events(capture / 'dmesg.xml'))
    client = list(xml_events(capture / 'client.xml'))
    failures = defaultdict(list)
    tests, signals, phase, milestones, fallbacks = [], [], [], [], []
    for event in guest:
        text = event['fields'].get('text', '')
        match = re.search(r"cannot execv\('([^']+)'\).*Exec format error", text)
        if match:
            failures[match[1]].append(guest_record(event))
        if re.search(r"Service 'boringssl_self_test.*exited with status", text):
            tests.append(guest_record(event))
        if "Service 'audioserver'" in text and 'received signal 9' in text:
            signals.append(guest_record(event))
        if 'vendor.sysprep.start_phase' in text or "starting service 'adbd'" in text or 'init.svc.adbd=' in text:
            phase.append(guest_record(event))
    event_counts = Counter(event['task'] for event in client)
    for event in client:
        if event['task'] in ('SessionConnected', 'SysPrepRedirectorConnected', 'Phase1InitStarted',
                             'StartPhase1Completed', 'UserBootCompleted', 'WindowFirstPresent'):
            milestones.append({'time': event['time'], 'xmlLine': event['xmlEventLine'], 'event': event['task'],
                               'windowName': event['fields'].get('windowName')})
        if event['task'] == 'FallbackError':
            f = event['fields']
            fallbacks.append({'time': event['time'], 'xmlLine': event['xmlEventLine'],
                              'hresult': hex(int(f['hresult'])), 'sourceFile': f.get('fileName', '').replace('\\', '/').rsplit('/', 1)[-1],
                              'sourceLine': int(f['lineNumber'])})
    report = {
        'schemaVersion': 1,
        'capture': capture.name,
        'sources': [source_info(capture / 'dmesg.xml'), source_info(capture / 'client.xml')],
        'execFormatFailures': [{'binary': binary, 'count': len(events), 'first': events[0], 'last': events[-1]}
                               for binary, events in failures.items()],
        'boringSslSelfTests': tests,
        'audioServerSigkill': {'count': len(signals), 'first': signals[0] if signals else None, 'last': signals[-1] if signals else None},
        'guestPhaseAndAdb': phase,
        'hostMilestones': milestones,
        'hostCompletionEventCounts': {key: event_counts[key] for key in ('StartPhase1Completed', 'UserBootCompleted', 'Phase1InitStarted')},
        'hostSocketFallbackErrors': fallbacks,
        'limits': ['A missing ETW event alone is not proof that an event cannot occur outside the capture window.',
                   'Guest logcat and ANR wall clocks initially use the build date (2024-12-06); use ETW host timestamps to correlate host time.',
                   'Only the audio-policy service wait is proven to block SystemServer by the supplied ANR; CAS/OMX/DRM/media failures are additional incompatibilities.'],
    }
    if logcat:
        report['sources'].append(source_info(logcat))
        waiting = matching_lines(logcat, r'AudioPolicyService not published|Waiting for service .media.audio_policy')
        report['audioPolicyWait'] = {'count': len(waiting), 'first': waiting[:3], 'last': waiting[-3:]}
        report['watchdog'] = matching_lines(logcat, r'WATCHDOG KILLING SYSTEM PROCESS|I watchdog: Blocked in handler')
        report['audioHalWait'] = matching_lines(logcat, r'getService: Trying again for android.hardware.audio@6.0::IDevicesFactory/default')[:3]
    if anr:
        report['sources'].append(source_info(anr))
        matches = matching_lines(anr, r'Subject:|ServiceManagerShim::getService|AudioSystem::get_audio_policy_service|AudioSystem::listAudioProductStrategies|AudioService\.<init>|SystemServer.startOtherServices')
        # Preserve symbolic frames while dropping native PCs and process-specific addresses.
        for entry in matches:
            entry['text'] = re.sub(r'pc [0-9a-f]+', 'pc <omitted>', entry['text'])
        report['mainThreadBlockingStack'] = matches
    if report.get('mainThreadBlockingStack') and report.get('audioPolicyWait', {}).get('count'):
        report['confirmedBlocker'] = 'SystemServer main thread is blocked constructing AudioService, waiting for media.audio_policy. The ARM32 vendor audio HAL fails ENOEXEC and its onrestart action repeatedly kills the 64-bit audioserver; the watchdog then restarts SystemServer.'
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('--logcat', type=Path)
    parser.add_argument('--anr', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    inputs = [args.capture / 'dmesg.xml', args.capture / 'client.xml', args.logcat, args.anr]
    if any(p and p.resolve() == args.report.resolve() for p in inputs):
        parser.error('Report must not overwrite input evidence')
    result = analyze(args.capture, args.logcat, args.anr)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'report': str(args.report), 'execFormatBinaries': len(result['execFormatFailures']),
                      'audioServerSigkillCount': result['audioServerSigkill']['count'],
                      'confirmedBlocker': result.get('confirmedBlocker')}, indent=2))


if __name__ == '__main__':
    main()
