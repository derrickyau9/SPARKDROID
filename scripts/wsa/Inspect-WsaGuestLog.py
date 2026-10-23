#!/usr/bin/env python3
"""Read local tracerpt XML and report the BoringSSL ARM32 boot failure.

No network, VM, process, or system-setting operations. The report includes only
selected diagnostic text and labels each VM by its local attempt number.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

NS = {'e': 'http://schemas.microsoft.com/win/2004/08/events/event'}
PATTERN = re.compile(
    r"cannot execv\('/vendor/bin/boringssl_self_test32'\)|"
    r"Service 'boringssl_self_test32_vendor'.*exited|"
    r"Service with 'reboot_on_failure'|Got shutdown_command|"
    r'Reboot start, reason:|Reboot ending, jumping to kernel')


def inspect(source: Path):
    raw = source.read_bytes()
    xml = raw.decode('utf-8-sig')  # Keep CRs intact for physical XML line numbers.
    records, attempts, events, tasks = [], {}, 0, Counter()
    guest_count = 0
    losses = {}
    processing_errors = []
    line, cursor = 1, 0
    for match in re.finditer(r'<Event\s[^>]*>.*?</Event>', xml, re.S):
        line += xml.count('\n', cursor, match.start())
        cursor = match.start()
        chunk = match.group()
        event = ET.fromstring(chunk)
        events += 1
        fields = {x.get('Name'): x.text or '' for x in event.findall('e:EventData/e:Data', NS)}
        task = event.findtext('e:RenderingInfo/e:Task', default='', namespaces=NS)
        tasks[task] += 1
        time = event.find('e:System/e:TimeCreated', NS).get('SystemTime')
        error = event.find('e:ProcessingErrorData', NS)
        if error is not None:
            processing_errors.append({'xmlLine': line, 'errorCode': error.findtext('e:ErrorCode', namespaces=NS)})
        for key in ('EventsLost', 'BuffersLost'):
            if key in fields:
                losses[key] = int(fields[key])
        vm_id = fields.get('vmId')
        if vm_id and vm_id not in attempts:
            attempts[vm_id] = len(attempts) + 1
        text = fields.get('text', '').strip()
        if text:
            guest_count += 1
        if not (PATTERN.search(text) or task == 'TerminateVm'):
            continue
        field = 'text' if text else 'exitDetails'
        field_pos = chunk.find(f'<Data Name="{field}">')
        result = {'attempt': attempts.get(vm_id), 'time': time,
                  'xmlEventLine': line,
                  'xmlDataLine': line + chunk.count('\n', 0, field_pos) if field_pos >= 0 else None}
        if text:
            result['text'] = text
        else:
            result['termination'] = json.loads(fields.get('exitDetails', '{}'))
        records.append(result)
    failed = {record['attempt'] for record in records
              if "cannot execv('/vendor/bin/boringssl_self_test32')" in record.get('text', '')}
    rebooted = {record['attempt'] for record in records
                if "Got shutdown_command 'reboot,boringssl-self-check-failed'" in record.get('text', '')}
    graceful = {record['attempt'] for record in records
                if record.get('termination', {}).get('ExitType') == 'GracefulExit'}
    confirmed = failed & rebooted & graceful
    if len(confirmed) == len(attempts) and attempts:
        finding = 'Every captured attempt fails to execute the vendor ARM32 BoringSSL self-test (ENOEXEC), then Android init requests reboot,boringssl-self-check-failed. The VM exits gracefully at the guest request.'
    elif failed:
        finding = f'{len(failed)} captured attempt(s) show an ARM32 BoringSSL execution failure; {len(confirmed)} include the subsequent BoringSSL reboot request and graceful exit.'
    else:
        finding = 'No vendor ARM32 BoringSSL execution failure was found in this capture. This alone does not establish a successful boot.'
    return {
        'schemaVersion': 1,
        'source': source.name,
        'sourceSha256': hashlib.sha256(raw).hexdigest(),
        'sourceBytes': len(raw),
        'eventCount': events,
        'guestLogTextCount': guest_count,
        'vmAttemptCount': len(attempts),
        'arm32BoringSslFailureAttempts': len(failed),
        'confirmedBoringSslShutdownAttempts': len(confirmed),
        'lossCounters': losses,
        'processingErrors': processing_errors,
        'finding': finding,
        'interpretationLimits': ['This identifies the immediate guest boot blocker, not proof that subsequent boot stages work.',
                                 'Exec format error alone does not distinguish missing kernel AArch32 support from unavailable CPU AArch32 EL0 support.',
                                 'Header decode errors are separate from successfully decoded GuestLog events.'],
        'evidence': records,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('xml', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    if args.xml.resolve() == args.report.resolve():
        parser.error('Report must not overwrite the input XML')
    report = inspect(args.xml)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({key: report[key] for key in ('eventCount', 'guestLogTextCount', 'vmAttemptCount', 'lossCounters', 'finding')}, indent=2))
    print(f'Report: {args.report}')


if __name__ == '__main__':
    main()
