#!/usr/bin/python3
"""Bound stalled Xcode test runs and clean up only their owned processes."""

import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import time


def identity(pid):
    result = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "lstart=", "-o", "comm="],
        capture_output=True,
        env={**os.environ, "LC_ALL": "C"},
        text=True,
        timeout=2,
    )
    fields = result.stdout.strip().split(None, 5)
    return tuple(fields) if len(fields) == 6 else None


def run(command, host_path, progress_timeout=30, startup_timeout=120):
    existing = set(subprocess.check_output(
        ["/bin/ps", "-axo", "pid="], text=True, timeout=2).split())
    hosts = {}
    interrupted = [None]
    previous = {}
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous[sig] = signal.signal(sig, lambda number, frame: interrupted.__setitem__(0, number))
    process = None
    result = 1
    last_output = last_progress = time.monotonic()
    testing = False
    pending = b""
    cleanup_errors = []

    def emit(data):
        try:
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
        except OSError:
            # A closed caller pipe must trigger cleanup, not interrupt cleanup itself.
            interrupted[0] = signal.SIGTERM

    def observe(data):
        nonlocal pending, testing, last_progress
        pending += data
        lines = pending.split(b"\n")
        pending = lines.pop()[-65536:]
        for raw in lines:
            line = raw.decode("utf-8", errors="replace").lstrip("\u200b ")
            match = re.search(r"QuickTTY\[(\d+):", line)
            if match and match[1] not in existing and int(match[1]) not in hosts:
                pid = int(match[1])
                try:
                    current = identity(pid)
                except subprocess.SubprocessError:
                    current = None
                if current and current[-1] == host_path:
                    hosts[pid] = current
                    if not testing:
                        testing = True
                        last_progress = time.monotonic()
            # Native output must not keep a stalled test alive indefinitely.
            if re.match(r"[◇✔✘] (Test|Suite) ", line) or line.startswith("Test Case ") or (
                line.startswith("Test Suite ") and "started" in line
            ):
                testing = True
                last_progress = time.monotonic()

    def signal_hosts(sig):
        for pid, original in hosts.items():
            try:
                if identity(pid) == original:
                    os.kill(pid, sig)
            except ProcessLookupError:
                pass
            except (OSError, subprocess.SubprocessError) as error:
                cleanup_errors.append(f"could not stop owned test host {pid}: {error}")

    def signal_group(sig):
        if process is not None:
            try:
                os.killpg(process.pid, sig)
            except ProcessLookupError:
                pass
            except PermissionError:
                # Darwin can report EPERM for a group containing only exited children.
                if process.poll() is None:
                    cleanup_errors.append("could not signal owned xcodebuild process group")

    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        fd = process.stdout.fileno()
        os.set_blocking(fd, False)
        eof = False
        while not eof or process.poll() is None:
            if interrupted[0] is not None:
                result = 128 + interrupted[0]
                break
            now = time.monotonic()
            if (testing and now - last_progress > progress_timeout) or (
                not testing and now - last_output > startup_timeout
            ):
                print("\nerror: Xcode test watchdog: no test progress; stopping owned run",
                      file=sys.stderr, flush=True)
                result = 124
                break
            if not eof and select.select([fd], [], [], 0.25)[0]:
                data = os.read(fd, 65536)
                if data:
                    last_output = time.monotonic()
                    observe(data)
                    emit(data)
                else:
                    eof = True
            elif eof:
                time.sleep(0.25)
        else:
            result = process.returncode
    finally:
        # launchd may parent test hosts; their logged PID, executable and start identity
        # are checked independently of the private xcodebuild process group.
        if process is not None:
            signal_hosts(signal.SIGTERM)
            signal_group(signal.SIGTERM)
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                if process.stdout and select.select([process.stdout], [], [], 0.1)[0]:
                    data = os.read(process.stdout.fileno(), 65536)
                    if data:
                        observe(data)
                        emit(data)
                        signal_hosts(signal.SIGTERM)
                time.sleep(0.1)
            signal_hosts(signal.SIGKILL)
            signal_group(signal.SIGKILL)
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                cleanup_errors.append("owned xcodebuild did not exit after SIGKILL")
            process.stdout.close()
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    if cleanup_errors:
        try:
            os.write(2, ("\nerror: " + "; ".join(cleanup_errors) + "\n").encode())
        except OSError:
            pass
        if result == 0:
            result = 1
    return result if result >= 0 else 128 - result


if __name__ == "__main__":
    command = sys.argv[1:]
    def option(name, default):
        return command[command.index(name) + 1] if name in command else default
    derived = option("-derivedDataPath", str(Path(__file__).resolve().parent.parent / ".build/DerivedData"))
    if "-derivedDataPath" not in command:
        command += ["-derivedDataPath", derived]
    configuration = option("-configuration", "Debug")
    host = str(Path(derived).resolve() / "Build/Products" / configuration /
               "QuickTTY.app/Contents/MacOS/QuickTTY")
    command += ["-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "30",
                "-maximum-test-execution-time-allowance", "60"]
    sys.exit(run(command, host))
