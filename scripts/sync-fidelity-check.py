#!/usr/bin/env python3
"""
Sync fidelity checker — compares beads JSONL against Linear issues.

Produces a detailed report on title, status, priority, and timestamp accuracy,
plus cron health and coverage metrics.
"""

import argparse
import json
import os
import re
from datetime import datetime, timezone


def load_linear_issues(path):
    with open(path) as f:
        data = json.load(f)
    return {n["identifier"]: n for n in data["data"]["team"]["issues"]["nodes"]}


def load_jsonl_beads(path):
    beads = {}
    with open(path) as f:
        for line in f:
            if not line.strip():
                continue
            b = json.loads(line)
            ref = b.get("external_ref", "")
            if ref:
                m = re.search(r"(KEV-\d+)", ref)
                if m:
                    beads[m.group(1)] = b
    return beads


STATUS_MAP = {
    "open": {"Todo", "Backlog", "Triage"},
    "in_progress": {"In Progress"},
    "closed": {"Done", "Canceled", "Cancelled", "Duplicate"},
}


def check_fidelity(linear_issues, jsonl_beads, sync_log_path, external_refs_path):
    overlap = sorted(set(jsonl_beads) & set(linear_issues))
    linear_only = sorted(set(linear_issues) - set(jsonl_beads))
    beads_only = sorted(set(jsonl_beads) - set(linear_issues))

    print("=" * 60)
    print("  BEADS-TO-LINEAR SYNC FIDELITY REPORT")
    print(f"  {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}")
    print("=" * 60)

    # ── Coverage ──
    print("\n── Coverage ──")
    print(f"  JSONL beads:      {len(jsonl_beads)}")
    print(f"  Linear issues:    {len(linear_issues)}")
    print(f"  Synced (overlap): {len(overlap)}")
    if beads_only:
        print(f"  Beads-only:       {len(beads_only)}  <- NOT in Linear")
        for k in beads_only[:5]:
            print(f"    {k}: {jsonl_beads[k].get('title', '')[:50]}")
    if linear_only:
        print(f"  Linear-only:      {len(linear_only)}  <- NOT in beads")
        for k in linear_only[:5]:
            print(f"    {k}: {linear_issues[k]['title'][:50]}")

    # ── Title fidelity ──
    print("\n── Title Fidelity ──")
    title_match = 0
    title_mismatches = []
    for key in overlap:
        bt = jsonl_beads[key].get("title", "").strip()
        lt = linear_issues[key]["title"].strip()
        if bt == lt:
            title_match += 1
        else:
            title_mismatches.append((key, bt[:40], lt[:40]))
    pct = title_match / max(1, len(overlap)) * 100
    print(f"  Match: {title_match}/{len(overlap)} ({pct:.1f}%)")
    if title_mismatches:
        for k, bt, lt in title_mismatches[:5]:
            print(f'    {k}: bead="{bt}"  linear="{lt}"')

    # ── Status fidelity ──
    print("\n── Status Fidelity ──")
    status_match = 0
    status_mismatches = []
    for key in overlap:
        bs = jsonl_beads[key].get("status", "open")
        ls = linear_issues[key]["state"]["name"]
        expected = STATUS_MAP.get(bs, set())
        if ls in expected:
            status_match += 1
        else:
            status_mismatches.append((key, bs, ls))
    pct = status_match / max(1, len(overlap)) * 100
    print(f"  Match: {status_match}/{len(overlap)} ({pct:.1f}%)")
    if status_mismatches:
        for k, bs, ls in status_mismatches[:5]:
            print(f"    {k}: bead={bs}  linear={ls}")

    # ── Priority fidelity ──
    print("\n── Priority Fidelity ──")
    pri_match = 0
    pri_mismatches = []
    for key in overlap:
        bp = jsonl_beads[key].get("priority", 0)
        lp = linear_issues[key].get("priority", 0)
        if bp == lp:
            pri_match += 1
        else:
            pri_mismatches.append((key, bp, lp))
    pct = pri_match / max(1, len(overlap)) * 100
    print(f"  Match: {pri_match}/{len(overlap)} ({pct:.1f}%)")
    if pri_mismatches:
        for k, bp, lp in pri_mismatches[:5]:
            print(f"    {k}: bead=P{bp}  linear=P{lp}")
        if len(pri_mismatches) > 5:
            print(f"    ... and {len(pri_mismatches) - 5} more")
        if pri_mismatches and len(pri_mismatches) == len(overlap):
            # Check for systematic offset
            offsets = [lp - bp for _, bp, lp in pri_mismatches]
            if len(set(offsets)) == 1:
                print(f"    ** SYSTEMATIC offset: Linear = bead + {offsets[0]}")

    # ── Timestamp drift ──
    print("\n── Timestamp Drift (updated_at) ──")
    drifts = []
    for key in overlap:
        bu = jsonl_beads[key].get("updated_at", "")
        lu = linear_issues[key].get("updatedAt", "")
        if bu and lu:
            try:
                bt = datetime.fromisoformat(bu.replace("Z", "+00:00"))
                lt = datetime.fromisoformat(lu.replace("Z", "+00:00"))
                drifts.append((key, abs((lt - bt).total_seconds())))
            except (ValueError, TypeError):
                pass

    if drifts:
        drifts.sort(key=lambda x: x[1], reverse=True)
        max_d = drifts[0][1]
        avg_d = sum(d for _, d in drifts) / len(drifts)
        vals = sorted(d for _, d in drifts)
        median_d = vals[len(vals) // 2]
        within_15m = sum(1 for _, d in drifts if d < 900)
        within_30m = sum(1 for _, d in drifts if d < 1800)
        print(f"  Max:     {max_d:>7.0f}s  ({max_d/60:.0f}min)")
        print(f"  Avg:     {avg_d:>7.0f}s  ({avg_d/60:.0f}min)")
        print(f"  Median:  {median_d:>7.0f}s  ({median_d/60:.0f}min)")
        print(f"  Within 15min: {within_15m}/{len(drifts)}")
        print(f"  Within 30min: {within_30m}/{len(drifts)}")

    # ── Pull cron health ──
    print("\n── Pull Cron Health ──")
    if os.path.exists(sync_log_path):
        with open(sync_log_path) as f:
            lines = f.readlines()
        successes = sum(1 for l in lines if "sync complete" in l.lower())
        failures = sum(1 for l in lines if "error" in l.lower())
        dns_fails = sum(1 for l in lines if "no such host" in l.lower())
        print(f"  Total runs:       {successes + failures}")
        print(f"  Successes:        {successes}")
        print(f"  Failures:         {failures}")
        if dns_fails:
            print(f"    DNS (offline):  {dns_fails}")
            print(f"    Other:          {failures - dns_fails}")
        connected = successes + (failures - dns_fails)
        if connected > 0:
            print(f"  Online success:   {successes}/{connected} ({successes/connected*100:.1f}%)")
    else:
        print("  (no sync log found)")

    # ── External refs ──
    print("\n── External Refs File ──")
    if os.path.exists(external_refs_path):
        with open(external_refs_path) as f:
            refs = json.load(f)
        jsonl_ids = {b.get("id") for b in jsonl_beads.values()}
        orphan_refs = [k for k in refs if k not in jsonl_ids]
        print(f"  Entries:  {len(refs)}")
        if orphan_refs:
            print(f"  Orphans:  {len(orphan_refs)} (in refs but not in JSONL)")
    else:
        print("  (no external_refs.json)")

    # ── Overall score ──
    print("\n" + "=" * 60)
    total_checks = len(overlap) * 3
    total_pass = title_match + status_match + pri_match
    overall = total_pass / max(1, total_checks) * 100
    grade = (
        "A" if overall >= 95 else
        "B" if overall >= 85 else
        "C" if overall >= 70 else
        "D" if overall >= 50 else
        "F"
    )
    print(f"  OVERALL FIDELITY: {total_pass}/{total_checks} = {overall:.1f}% (grade: {grade})")

    issues = []
    if pri_mismatches:
        issues.append("priority mapping misconfigured")
    if status_mismatches:
        issues.append(f"{len(status_mismatches)} status mismatches")
    if title_mismatches:
        issues.append(f"{len(title_mismatches)} title mismatches")
    if drifts and max_d > 3600:
        issues.append(f"max timestamp drift {max_d/60:.0f}min")

    if issues:
        print(f"  ACTION ITEMS: {'; '.join(issues)}")

    print("=" * 60)
    return 0 if overall >= 95 else 1


def main():
    parser = argparse.ArgumentParser(description="Sync fidelity checker")
    parser.add_argument("--linear", required=True, help="Path to Linear API response JSON")
    parser.add_argument("--jsonl", required=True, help="Path to issues.jsonl")
    parser.add_argument("--sync-log", default=os.path.expanduser("~/.beads-sync.log"))
    parser.add_argument("--external-refs", default=".beads/external_refs.json")
    args = parser.parse_args()

    linear_issues = load_linear_issues(args.linear)
    jsonl_beads = load_jsonl_beads(args.jsonl)
    exit_code = check_fidelity(linear_issues, jsonl_beads, args.sync_log, args.external_refs)
    raise SystemExit(exit_code)


if __name__ == "__main__":
    main()
