#!/usr/bin/env python3
"""Check Developer ID profile metadata and the final app's Keychain signing inputs."""

import datetime
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile
import uuid

BUNDLE_ID = "com.dntsk.QuickTTY"
MAXIMUM_PROFILE_BYTES = 1024 * 1024


class InvalidProfile(Exception):
    pass


def validate_profile(profile, team, now=None):
    if not isinstance(team, str) or not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise InvalidProfile("invalid development team")
    if not isinstance(profile, dict):
        raise InvalidProfile("profile is not a dictionary")
    try:
        uuid.UUID(profile["UUID"])
    except (KeyError, ValueError, TypeError, AttributeError):
        raise InvalidProfile("invalid profile UUID") from None
    if profile.get("Platform") != ["OSX"]:
        raise InvalidProfile("profile must target macOS")
    if profile.get("TeamIdentifier") != [team] or profile.get("ApplicationIdentifierPrefix") != [team]:
        raise InvalidProfile("profile team or App ID prefix mismatch")
    if profile.get("ProvisionsAllDevices") is not True or profile.get("ProvisionedDevices"):
        raise InvalidProfile("profile must allow distribution without registered devices")
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime.datetime):
        raise InvalidProfile("profile has no valid expiration date")
    if expiration.tzinfo is not None:
        expiration = expiration.astimezone(datetime.timezone.utc).replace(tzinfo=None)
    if expiration <= (now or datetime.datetime.utcnow()):
        raise InvalidProfile("profile has expired")
    certificates = profile.get("DeveloperCertificates")
    if not isinstance(certificates, list) or not certificates or not all(
        isinstance(certificate, bytes) and certificate for certificate in certificates
    ):
        raise InvalidProfile("profile has no valid signing certificates")
    app_id = team + "." + BUNDLE_ID
    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict):
        raise InvalidProfile("profile has no entitlements")
    if entitlements.get("com.apple.application-identifier") != app_id:
        raise InvalidProfile("profile application identifier mismatch")
    if entitlements.get("com.apple.developer.team-identifier") != team:
        raise InvalidProfile("profile entitlement team mismatch")
    for key in ["get-task-allow", "com.apple.security.get-task-allow"]:
        if entitlements.get(key, False) is not False:
            raise InvalidProfile("profile permits debugging")
    groups = entitlements.get("keychain-access-groups")
    if not isinstance(groups, list) or not groups or not all(
        group in (app_id, team + ".*") for group in groups
    ):
        raise InvalidProfile("profile does not authorize the application's Keychain group")
    # The explicit app-only group preserves the connection saved by the development build.
    return {"com.apple.application-identifier": app_id, "keychain-access-groups": [app_id]}


def validate_signature(profile, entitlements, certificate, team, now=None):
    expected = validate_profile(profile, team, now)
    if certificate not in profile["DeveloperCertificates"]:
        raise InvalidProfile("app signing certificate is not authorized by the profile")
    if entitlements != expected:
        raise InvalidProfile("final app Keychain entitlements are not exact")


def command_output(arguments):
    try:
        return subprocess.run(arguments, check=True, capture_output=True, timeout=30).stdout
    except (subprocess.SubprocessError, OSError):
        raise InvalidProfile("signing metadata inspection failed") from None


def load_profile(path):
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise InvalidProfile("profile must be an absolute regular non-symlink file")
    if path.suffix != ".provisionprofile" or path.stat().st_size > MAXIMUM_PROFILE_BYTES:
        raise InvalidProfile("invalid provisioning profile file")
    data = path.read_bytes()
    decoded = command_output(["/usr/bin/security", "cms", "-D", "-i", str(path)])
    try:
        return plistlib.loads(decoded), data
    except plistlib.InvalidFileException:
        raise InvalidProfile("invalid CMS profile payload") from None


def signing_certificate(app):
    with tempfile.TemporaryDirectory(prefix="quicktty-profile-certificate-") as temporary:
        prefix = pathlib.Path(temporary) / "certificate-"
        command_output(["/usr/bin/codesign", "-d", "--extract-certificates=" + str(prefix), str(app)])
        leaf = pathlib.Path(str(prefix) + "0")
        if not leaf.is_file():
            raise InvalidProfile("app signing certificate is missing")
        return leaf.read_bytes()


def main(arguments):
    if len(arguments) < 3 or arguments[0] not in ("profile", "prepare", "verify"):
        raise InvalidProfile("expected profile, prepare or verify operation")
    operation, profile_path, team = arguments[:3]
    expected_count = {"profile": 3, "prepare": 5, "verify": 4}[operation]
    if len(arguments) != expected_count:
        raise InvalidProfile("invalid argument count")
    profile, data = load_profile(pathlib.Path(profile_path))
    expected = validate_profile(profile, team)
    if operation != "profile":
        app = pathlib.Path(arguments[3])
        certificate = signing_certificate(app)
        validate_signature(profile, expected, certificate, team)
        if operation == "prepare":
            destination = pathlib.Path(arguments[4])
            with destination.open("xb") as output:
                plistlib.dump(expected, output)
        else:
            embedded = app / "Contents/embedded.provisionprofile"
            if embedded.is_symlink() or not embedded.is_file() or embedded.read_bytes() != data:
                raise InvalidProfile("final app does not embed the exact approved profile")
            encoded = command_output(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)])
            try:
                entitlements = plistlib.loads(encoded)
            except plistlib.InvalidFileException:
                raise InvalidProfile("cannot decode final app entitlements") from None
            validate_signature(profile, entitlements, certificate, team)
    print("Developer ID Keychain " + operation + " validated: " + profile["UUID"])


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (InvalidProfile, OSError, ValueError, TypeError) as error:
        print("error: release Keychain validation failed: " + str(error), file=sys.stderr)
        sys.exit(1)
