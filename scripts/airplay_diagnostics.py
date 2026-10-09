#!/usr/bin/env python3
"""Read-only AirPlay evidence. Raw logs and endpoint identities never leave memory."""
import argparse
import datetime
import ipaddress
import json
import math
import pathlib
import re
import socket
import statistics
import subprocess
import time


SCREEN_FIELDS = {
    "Sent Frames", "Dropped Overflow Frames", "Dropped Frames", "Encoded Frames",
    "durationMs", "activationMs", "setupMs", "resolveMs", "pairingMs",
}


def numeric_screen_fields(value):
    result = {}
    if isinstance(value, dict):
        for key, item in value.items():
            if key in SCREEN_FIELDS and isinstance(item, (int, float)) and not isinstance(item, bool):
                if math.isfinite(item):
                    result[key] = item
            elif isinstance(item, (dict, list)):
                result.update(numeric_screen_fields(item))
    elif isinstance(value, list):
        for item in value:
            result.update(numeric_screen_fields(item))
    return result


def screen_metrics(seconds):
    predicate = 'subsystem == "com.apple.airplay" AND eventMessage CONTAINS "sessionType" AND eventMessage CONTAINS "Screen"'
    try:
        command = subprocess.run(
            ["/usr/bin/log", "show", "--last", f"{seconds}s", "--style", "json", "--predicate", predicate],
            capture_output=True, text=True, timeout=20,
        )
        if command.returncode != 0:
            return {"available": False, "reason": "The system log could not be read."}
        rows = json.loads(command.stdout)
    except (subprocess.SubprocessError, ValueError, OSError):
        return {"available": False, "reason": "No readable screen-sender statistics."}
    records = []
    for row in rows:
        message = row.get("eventMessage", "")
        if not re.search(r'"sessionType"\s*:\s*"Screen"', message):
            continue
        for opening in re.finditer(r"\{", message):
            try:
                value, _ = json.JSONDecoder().raw_decode(message[opening.start():])
            except ValueError:
                continue
            fields = numeric_screen_fields(value)
            if fields:
                records.append(fields)
            break
    return {
        "available": bool(records), "lookback_seconds": seconds,
        "records": records[-3:],
        "limits": "Completion metrics may appear only after disconnecting. They describe the sender session, not visible TV latency or a delivered frame rate.",
    }


def summarize(values):
    if not values:
        return None
    return {"minimum_ms": round(min(values), 3), "median_ms": round(statistics.median(values), 3),
            "maximum_ms": round(max(values), 3), "samples": len(values)}


def lan_metrics(host):
    address = ipaddress.ip_address(host)
    # Keep this deliberately narrow: neither hostname resolution nor public targets.
    private_v4 = [ipaddress.ip_network(x) for x in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16")]
    if address.version != 4 or not any(address in network for network in private_v4):
        raise ValueError("Supply the TV's local IPv4 address; public targets are refused.")
    values, failures = [], 0
    for _ in range(3):
        start = time.monotonic()
        try:
            with socket.create_connection((str(address), 7000), timeout=2):
                values.append((time.monotonic() - start) * 1000)
        except OSError:
            failures += 1
        time.sleep(0.2)
    result = {"tcp_7000_connection": summarize(values), "tcp_failures": failures}
    try:
        command = subprocess.run(["/sbin/ping", "-n", "-c", "5", "-i", "0.3", str(address)],
                                 capture_output=True, text=True, timeout=10)
        packet_loss = re.search(r"([\d.]+)% packet loss", command.stdout)
        times = [float(x) for x in re.findall(r"time[=<]([\d.]+) ms", command.stdout)]
        result["icmp_rtt"] = summarize(times)
        result["icmp_packet_loss_percent"] = float(packet_loss.group(1)) if packet_loss else None
    except (subprocess.SubprocessError, OSError):
        result["icmp_rtt"] = None
    result["limits"] = "Five ICMP samples and three TCP handshakes are a small LAN check, not throughput, video delivery, or visible latency measurements. Missing ICMP replies may reflect filtering."
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--display-helper", required=True)
    parser.add_argument("--host", help="Optional local IPv4 address; not written to the report.")
    parser.add_argument("--lookback-seconds", type=int, default=120)
    parser.add_argument("--output", type=pathlib.Path, help="Optional sanitized JSON report.")
    args = parser.parse_args()
    if not 1 <= args.lookback_seconds <= 1800:
        parser.error("--lookback-seconds must be between 1 and 1800")
    try:
        display = subprocess.run([args.display_helper], capture_output=True, text=True, check=True, timeout=30)
        report = {
            "schema_version": 1,
            "captured_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "display": json.loads(display.stdout),
            "screen_sender": screen_metrics(args.lookback_seconds),
            "visible_latency_ms": None,
            "privacy": "No device names, addresses, SSIDs, unique hardware identifiers, pairing tokens, raw logs, or media paths are included.",
        }
        if args.host:
            report["lan"] = lan_metrics(args.host)
    except (subprocess.SubprocessError, ValueError, OSError):
        parser.exit(1, "Diagnostics could not be completed. Check prerequisites and the local TV address.\n")
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded)
    else:
        print(encoded, end="")


if __name__ == "__main__":
    main()
