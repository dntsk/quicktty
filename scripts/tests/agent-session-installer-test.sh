#!/bin/sh
set -eu

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
repo_root=$(CDPATH= cd -P "$script_dir/../.." && pwd -P)
TMPDIR=${TMPDIR:-/tmp}
tmp_base=$(CDPATH= cd -P "$TMPDIR" && pwd -P)
test_root=

cleanup() {
    status=$?
    trap - 0 HUP INT TERM
    case "${test_root:-}" in
        "$tmp_base"/quicktty-agent-session-installer-test.*)
            [ ! -L "$test_root" ] && [ -d "$test_root" ] && /bin/rm -rf "$test_root"
            ;;
        "") ;;
        *) printf 'FAIL: refusing to remove unexpected path: %s\n' "$test_root" >&2 ;;
    esac
    exit "$status"
}
trap cleanup 0 HUP INT TERM

test_root=$(/usr/bin/mktemp -d "$tmp_base/quicktty-agent-session-installer-test.XXXXXX")
case "$test_root" in
    "$tmp_base"/quicktty-agent-session-installer-test.*) ;;
    *) fail 'temporary root has an unexpected path' ;;
esac

helper_dir=$test_root/helper
helper=$helper_dir/quicktty
home=$test_root/home
fake_bin=$test_root/bin
logs=$test_root/logs
secret='TASK15_FIXTURE_SECRET_DO_NOT_PRINT'
/bin/mkdir -p "$helper_dir" "$home/Library/Application Support" "$fake_bin" "$logs"
/bin/cp -R "$repo_root/QuickTTY/Resources/AgentSessionIntegrations" "$helper_dir/AgentSessionIntegrations"

/usr/bin/xcrun --sdk macosx swiftc \
    "$repo_root"/Shared/AgentIntegrations/*.swift \
    "$repo_root"/Shared/AgentIntegrations/Installer/*.swift \
    "$repo_root"/QuickTTYCLI/*.swift \
    -o "$helper"

for executable in pi omp; do
    printf '#!/bin/sh\nexit 0\n' >"$fake_bin/$executable"
    /bin/chmod 700 "$fake_bin/$executable"
done
export HOME=$home
export PATH=$fake_bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin

"$helper" integrations status >"$logs/status" 2>"$logs/status.err"
[ "$(/usr/bin/wc -l <"$logs/status" | /usr/bin/tr -d ' ')" = 20 ] \
    || fail 'status did not report the exact 20 adapters'
[ ! -e "$home/QuickTTY" ] && [ ! -e "$home/.pi" ] \
    || fail 'status mutated synthetic HOME'

set +e
printf 'yes\n' | "$helper" integrations install pi >"$logs/noninteractive" 2>"$logs/noninteractive.err"
noninteractive_status=$?
set -e
[ "$noninteractive_status" = 2 ] || fail 'noninteractive mutation without --yes did not return 2'
[ ! -e "$home/.pi" ] || fail 'noninteractive mutation without --yes wrote files'

/usr/bin/python3 - "$helper" "$logs/literal-yes" <<'PY'
import os
import pty
import select
import sys

helper, output_path = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    os.execve(helper, [helper, "integrations", "install", "pi"], os.environ)
data = bytearray()
sent = False
timed_out = False
try:
    while True:
        ready, _, _ = select.select([fd], [], [], 5)
        if not ready:
            timed_out = True
            raise SystemExit("interactive installer timed out")
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if chunk == b"":
            break
        data.extend(chunk)
        if not sent and b"Type yes:" in data:
            os.write(fd, b"yes\n")
            sent = True
finally:
    os.close(fd)
    if timed_out:
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)
if not timed_out:
    _, status = os.waitpid(pid, 0)
with open(output_path, "wb") as output:
    output.write(data)
if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0 or not sent:
    raise SystemExit("literal yes did not apply")
PY
pi_extension="$home/.pi/agent/extensions/quicktty-session/index.ts"
[ -f "$pi_extension" ] || fail 'literal yes did not install the official Pi extension path'
[ "$(/usr/bin/stat -f '%Lp' "$pi_extension")" = 600 ] \
    || fail 'Pi extension mode is not 0600'
/usr/bin/grep -F 'pi.on("session_start"' "$pi_extension" >/dev/null \
    || fail 'Pi extension does not subscribe to session_start'
/usr/bin/grep -F 'pi.on("session_shutdown"' "$pi_extension" >/dev/null \
    || fail 'Pi extension does not subscribe to session_shutdown'
/usr/bin/grep -F 'spawn(HELPER_PATH, ["internal", "hook", "pi", event]' "$pi_extension" >/dev/null \
    || fail 'Pi extension does not use structured helper argv'

pi_package=/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent
pi_types=$pi_package/dist/core/extensions/types.d.ts
[ "$(/opt/homebrew/bin/node -p "require('$pi_package/package.json').version")" = 0.83.0 ] \
    || fail 'installed Pi SDK is not the required 0.83.0'
for type_contract in \
    'on(event: "session_start"' \
    'on(event: "session_shutdown"' \
    'reason: "quit" | "reload" | "new" | "resume" | "fork"'
do
    /usr/bin/grep -F "$type_contract" "$pi_types" >/dev/null \
        || fail "installed Pi SDK type contract is missing: $type_contract"
done
"$pi_package/node_modules/.bin/jiti" "$pi_extension" >/dev/null 2>&1 \
    || fail 'Pi extension did not compile with the installed Pi TypeScript loader'

pi_contract_dir=$test_root/pi-contract
pi_contract_extension=$pi_contract_dir/index.ts
pi_contract_helper=$pi_contract_dir/helper.py
pi_contract_log=$pi_contract_dir/events.jsonl
pi_contract_harness=$pi_contract_dir/contract.ts
/bin/mkdir -p "$pi_contract_dir"
/usr/bin/python3 - \
    "$repo_root/QuickTTY/Resources/AgentSessionIntegrations/pi/index.ts" \
    "$pi_contract_extension" "$pi_contract_helper" <<'PY'
import json
import pathlib
import sys

template, output, helper = map(pathlib.Path, sys.argv[1:])
source = template.read_text()
placeholder = '"__QUICKTTY_HELPER_PATH__"'
if source.count(placeholder) != 1:
    raise SystemExit("Pi helper placeholder is not exact")
source = source.replace(placeholder, json.dumps(str(helper)))
output.write_text(source)
PY
cat >"$pi_contract_helper" <<'PY'
#!/usr/bin/python3
import json
import os
import sys

record = {"arguments": sys.argv[1:], "payload": json.load(sys.stdin)}
with open(os.environ["QUICKTTY_PI_CONTRACT_LOG"], "a", encoding="utf-8") as output:
    output.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
PY
/bin/chmod 700 "$pi_contract_helper"
cat >"$pi_contract_harness" <<'TS'
import type {
  ExtensionAPI,
  SessionShutdownEvent,
  SessionStartEvent,
} from "@earendil-works/pi-coding-agent";
import quickTTYSessionIntegration from "./index.ts";

type Handler = (event: SessionStartEvent | SessionShutdownEvent, context: unknown) => Promise<void>;

class FakePiAPI {
  readonly handlers = new Map<string, Handler>();

  on(event: string, handler: Handler): void {
    this.handlers.set(event, handler);
  }
}

function context(sessionID: string, cwd: string): unknown {
  return {
    cwd,
    sessionManager: { getSessionId: () => sessionID },
  };
}

async function emit(
  api: FakePiAPI,
  event: SessionStartEvent | SessionShutdownEvent,
  eventContext: unknown,
): Promise<void> {
  const handler = api.handlers.get(event.type);
  if (!handler) throw new Error(`missing handler: ${event.type}`);
  await handler(event, eventContext);
}

async function main(): Promise<void> {
  delete (globalThis as typeof globalThis & {
    __quickttySessionIntegrationState?: unknown;
  }).__quickttySessionIntegrationState;

  const first = new FakePiAPI();
  quickTTYSessionIntegration(first as unknown as ExtensionAPI);
  await emit(
    first,
    { type: "session_start", reason: "startup" },
    context("session-old", "/tmp/old"),
  );
  await emit(
    first,
    {
      type: "session_shutdown",
      reason: "resume",
      targetSessionFile: "/sessions/new.jsonl",
    },
    context("session-old", "/tmp/old"),
  );

  const replacement = new FakePiAPI();
  quickTTYSessionIntegration(replacement as unknown as ExtensionAPI);
  await emit(
    replacement,
    {
      type: "session_start",
      reason: "resume",
      previousSessionFile: "/sessions/old.jsonl",
    },
    context("session-new", "/tmp/new"),
  );
  await emit(
    replacement,
    { type: "session_shutdown", reason: "quit" },
    context("session-new", "/tmp/new"),
  );
}

void main().catch((error: unknown) => {
  process.stderr.write(`${String(error)}\n`);
  process.exitCode = 1;
});
TS
QUICKTTY_PI_CONTRACT_LOG=$pi_contract_log \
    "$pi_package/node_modules/.bin/jiti" "$pi_contract_harness" >/dev/null 2>&1 \
    || fail 'Pi lifecycle contract harness did not compile and run'
/usr/bin/python3 - "$pi_contract_log" <<'PY'
import json
import pathlib
import sys

records = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
expected = [
    {
        "arguments": ["internal", "hook", "pi", "session_start"],
        "payload": {"cwd": "/tmp/old", "session_id": "session-old"},
    },
    {
        "arguments": ["internal", "hook", "pi", "session_switch"],
        "payload": {
            "cwd": "/tmp/new",
            "previous_session_id": "session-old",
            "session_id": "session-new",
        },
    },
    {
        "arguments": ["internal", "hook", "pi", "session_shutdown"],
        "payload": {"reason": "quit", "session_id": "session-new"},
    },
]
if records != expected:
    raise SystemExit(f"unexpected Pi lifecycle payloads: {records!r}")
PY

"$helper" integrations install pi --yes >"$logs/idempotent" 2>"$logs/idempotent.err"
if /usr/bin/find "$home" -name '*.quicktty-backup-*' -print | /usr/bin/grep . >/dev/null; then
    fail 'idempotent install created a backup'
fi

"$helper" integrations install grok --yes >"$logs/blocked" 2>"$logs/blocked.err"
/usr/bin/grep -F 'grok: blocked skipped' "$logs/blocked" >/dev/null \
    || fail 'blocked adapter was not skipped'

/usr/bin/python3 - "$helper" "$home" "$logs/race" <<'PY'
import os
import pty
import select
import sys

helper, home, output_path = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    os.execve(helper, [helper, "integrations", "install", "omp"], os.environ)
data = bytearray()
sent = False
timed_out = False
try:
    while True:
        ready, _, _ = select.select([fd], [], [], 5)
        if not ready:
            timed_out = True
            raise SystemExit("race installer timed out")
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if chunk == b"":
            break
        data.extend(chunk)
        if not sent and b"Type yes:" in data:
            path = os.path.join(home, ".omp", "extensions", "quicktty-session.json")
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as output:
                output.write(b"user race value")
            os.write(fd, b"yes\n")
            sent = True
finally:
    os.close(fd)
    if timed_out:
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)
if not timed_out:
    _, status = os.waitpid(pid, 0)
with open(output_path, "wb") as output:
    output.write(data)
if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 1 or not sent:
    raise SystemExit("preview race was not rejected")
PY
[ "$(/bin/cat "$home/.omp/extensions/quicktty-session.json")" = 'user race value' ] \
    || fail 'race changed user content'

printf '%s\n' "$secret" >"$home/.pi/agent/extensions/quicktty-session/index.ts"
set +e
"$helper" integrations uninstall pi --yes >"$logs/uninstall" 2>"$logs/uninstall.err"
uninstall_status=$?
set -e
[ "$uninstall_status" = 1 ] || fail 'owned-file conflict did not return 1'
[ "$(/bin/cat "$home/.pi/agent/extensions/quicktty-session/index.ts")" = "$secret" ] \
    || fail 'uninstall removed user content'

launcher_source=$test_root/LauncherHarness.swift
cat >"$launcher_source" <<'SWIFT'
import Foundation

@main
struct LauncherHarness {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let helper = URL(fileURLWithPath: arguments[2])
        let ownedHome = root.appending(path: "owned", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: ownedHome, withIntermediateDirectories: true)
        let installer = try CommandLineLauncherInstaller(
            homeDirectory: ownedHome,
            helperExecutable: helper
        )
        let install = try await installer.prepare(action: .install)
        guard try await installer.apply(planID: install.planID) == .succeeded else { exit(10) }
        let launcher = ownedHome.appending(path: ".local/bin/quicktty")
        guard try FileManager.default.destinationOfSymbolicLink(atPath: launcher.path) == helper.path else { exit(11) }
        let localMode = try FileManager.default.attributesOfItem(atPath: ownedHome.appending(path: ".local").path)[.posixPermissions] as? NSNumber
        let binMode = try FileManager.default.attributesOfItem(atPath: launcher.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        guard localMode?.intValue == 0o700, binMode?.intValue == 0o700 else { exit(12) }
        let uninstall = try await installer.prepare(action: .uninstall)
        guard try await installer.apply(planID: uninstall.planID) == .succeeded else { exit(13) }

        let preservedHome = root.appending(path: "preserved", directoryHint: .isDirectory)
        let preservedBin = preservedHome.appending(path: ".local/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: preservedBin, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: preservedHome.appending(path: ".local").path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: preservedBin.path)
        let preservedInstaller = try CommandLineLauncherInstaller(homeDirectory: preservedHome, helperExecutable: helper)
        let preservedInstall = try await preservedInstaller.prepare(action: .install)
        _ = try await preservedInstaller.apply(planID: preservedInstall.planID)
        let preservedUninstall = try await preservedInstaller.prepare(action: .uninstall)
        _ = try await preservedInstaller.apply(planID: preservedUninstall.planID)
        let preservedLocalMode = try FileManager.default.attributesOfItem(atPath: preservedHome.appending(path: ".local").path)[.posixPermissions] as? NSNumber
        let preservedBinMode = try FileManager.default.attributesOfItem(atPath: preservedBin.path)[.posixPermissions] as? NSNumber
        guard preservedLocalMode?.intValue == 0o755, preservedBinMode?.intValue == 0o755 else { exit(14) }

        for foreignKind in ["regular", "symlink"] {
            let raceHome = root.appending(path: "race-\(foreignKind)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: raceHome, withIntermediateDirectories: true)
            let raceLauncher = raceHome.appending(path: ".local/bin/quicktty")
            let raceInstaller = try CommandLineLauncherInstaller(
                homeDirectory: raceHome,
                helperExecutable: helper,
                beforeUninstallSwap: {
                    try FileManager.default.removeItem(at: raceLauncher)
                    if foreignKind == "regular" {
                        try Data("foreign launcher".utf8).write(to: raceLauncher)
                    } else {
                        try FileManager.default.createSymbolicLink(
                            at: raceLauncher,
                            withDestinationURL: URL(fileURLWithPath: "/usr/bin/false")
                        )
                    }
                }
            )
            let raceInstall = try await raceInstaller.prepare(action: .install)
            _ = try await raceInstaller.apply(planID: raceInstall.planID)
            let raceUninstall = try await raceInstaller.prepare(action: .uninstall)
            do {
                _ = try await raceInstaller.apply(planID: raceUninstall.planID)
                exit(15)
            } catch AgentIntegrationInstallerError.changedAfterPreview {}
            if foreignKind == "regular" {
                guard try Data(contentsOf: raceLauncher) == Data("foreign launcher".utf8) else { exit(16) }
            } else {
                guard try FileManager.default.destinationOfSymbolicLink(atPath: raceLauncher.path) == "/usr/bin/false" else { exit(17) }
            }
            let raceEntries = try FileManager.default.contentsOfDirectory(atPath: raceLauncher.deletingLastPathComponent().path)
            guard raceEntries == ["quicktty"] else { exit(18) }
        }

        let quarantineRaceHome = root.appending(path: "quarantine-race", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: quarantineRaceHome, withIntermediateDirectories: true)
        let quarantineRaceLauncher = quarantineRaceHome.appending(path: ".local/bin/quicktty")
        let quarantineRaceInstaller = try CommandLineLauncherInstaller(
            homeDirectory: quarantineRaceHome,
            helperExecutable: helper,
            beforeUninstallQuarantine: {
                try FileManager.default.removeItem(at: quarantineRaceLauncher)
                try Data("quarantine foreign".utf8).write(to: quarantineRaceLauncher)
            }
        )
        let quarantineRaceInstall = try await quarantineRaceInstaller.prepare(action: .install)
        _ = try await quarantineRaceInstaller.apply(planID: quarantineRaceInstall.planID)
        let quarantineRaceUninstall = try await quarantineRaceInstaller.prepare(action: .uninstall)
        do {
            _ = try await quarantineRaceInstaller.apply(planID: quarantineRaceUninstall.planID)
            exit(19)
        } catch AgentIntegrationInstallerError.changedAfterPreview {}
        guard try Data(contentsOf: quarantineRaceLauncher) == Data("quarantine foreign".utf8) else { exit(20) }
        let quarantineRaceEntries = try FileManager.default.contentsOfDirectory(atPath: quarantineRaceLauncher.deletingLastPathComponent().path)
        guard quarantineRaceEntries == ["quicktty"] else { exit(21) }

        let conflictHome = root.appending(path: "conflict", directoryHint: .isDirectory)
        let conflict = conflictHome.appending(path: ".local/bin/quicktty")
        try FileManager.default.createDirectory(at: conflict.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user launcher".utf8).write(to: conflict)
        let conflictInstaller = try CommandLineLauncherInstaller(
            homeDirectory: conflictHome,
            helperExecutable: helper
        )
        let plan = try await conflictInstaller.prepare(action: .install)
        guard plan.status == .conflict, (try Data(contentsOf: conflict)) == Data("user launcher".utf8) else { exit(22) }
    }
}
SWIFT
launcher_harness=$test_root/launcher-harness
/usr/bin/xcrun --sdk macosx swiftc -parse-as-library \
    "$repo_root"/Shared/AgentIntegrations/Installer/*.swift "$launcher_source" \
    -o "$launcher_harness"
"$launcher_harness" "$test_root/launcher" "$helper" >"$logs/launcher" 2>"$logs/launcher.err"

if /usr/bin/grep -R -F "$secret" "$logs" >/dev/null; then
    fail 'installer output exposed fixture secret'
fi
for rc in .zshrc .bashrc .bash_profile .profile; do
    [ ! -e "$home/$rc" ] || fail "installer modified shell startup file: $rc"
done

printf 'Agent session installer contract tests passed.\n'
