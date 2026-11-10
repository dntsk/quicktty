#!/usr/bin/env python3
import datetime
import importlib.util
import pathlib
import sys
import unittest

sys.dont_write_bytecode = True

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_keychain", ROOT / "scripts/release-keychain.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

TEAM = "ABCDE12345"
APP_ID = TEAM + ".com.dntsk.QuickTTY"
NOW = datetime.datetime(2026, 1, 1)


def profile():
    return {
        "UUID": "11e8ef50-2833-419a-92f8-e44d38ca2cf8",
        "Platform": ["OSX"],
        "TeamIdentifier": [TEAM],
        "ApplicationIdentifierPrefix": [TEAM],
        "ProvisionsAllDevices": True,
        "ExpirationDate": NOW + datetime.timedelta(days=365),
        "DeveloperCertificates": [b"public-certificate-fixture"],
        "Entitlements": {
            "com.apple.application-identifier": APP_ID,
            "com.apple.developer.team-identifier": TEAM,
            "keychain-access-groups": [TEAM + ".*"],
        },
    }


class ReleaseKeychainTests(unittest.TestCase):
    def test_production_profile_preserves_existing_connection_access_group(self):
        expected = MODULE.validate_profile(profile(), TEAM, NOW)
        self.assertEqual(expected, {
            "com.apple.application-identifier": APP_ID,
            "keychain-access-groups": [APP_ID],
        })
        exact = profile()
        exact["Entitlements"]["keychain-access-groups"] = [APP_ID]
        self.assertEqual(MODULE.validate_profile(exact, TEAM, NOW), expected)

    def test_rejects_development_foreign_expired_and_malformed_profiles(self):
        mutations = [
            ("ProvisionsAllDevices", False),
            ("ProvisionsAllDevices", 1),
            ("ProvisionedDevices", ["another-mac"]),
            ("Platform", ["iOS"]),
            ("TeamIdentifier", ["OTHER12345"]),
            ("ApplicationIdentifierPrefix", ["OTHER12345"]),
            ("ExpirationDate", NOW),
            ("ExpirationDate", "not a date"),
            ("DeveloperCertificates", []),
            ("DeveloperCertificates", ["not DER bytes"]),
            ("UUID", "not a UUID"),
        ]
        for field, value in mutations:
            with self.subTest(field=field, value=value):
                invalid = profile()
                invalid[field] = value
                with self.assertRaises(MODULE.InvalidProfile):
                    MODULE.validate_profile(invalid, TEAM, NOW)
        for field in ["ProvisionsAllDevices", "ExpirationDate", "Entitlements"]:
            invalid = profile()
            del invalid[field]
            with self.assertRaises(MODULE.InvalidProfile):
                MODULE.validate_profile(invalid, TEAM, NOW)

    def test_rejects_wrong_entitlements_and_debugging_privileges(self):
        changes = [
            {"com.apple.application-identifier": TEAM + ".another-app"},
            {"com.apple.application-identifier": TEAM + ".*"},
            {"com.apple.developer.team-identifier": "OTHER12345"},
            {"keychain-access-groups": ["OTHER12345.*"]},
            {"keychain-access-groups": [TEAM + ".another-app"]},
            {"keychain-access-groups": "not an array"},
            {"get-task-allow": True},
            {"com.apple.security.get-task-allow": True},
        ]
        for change in changes:
            with self.subTest(change=change):
                invalid = profile()
                invalid["Entitlements"].update(change)
                with self.assertRaises(MODULE.InvalidProfile):
                    MODULE.validate_profile(invalid, TEAM, NOW)

    def test_signed_app_entitlements_and_certificate_are_exact(self):
        payload = profile()
        entitlements = MODULE.validate_profile(payload, TEAM, NOW)
        certificate = payload["DeveloperCertificates"][0]
        MODULE.validate_signature(payload, entitlements, certificate, TEAM, NOW)
        invalid_cases = [
            {},
            {**entitlements, "com.apple.security.get-task-allow": False},
            {**entitlements, "keychain-access-groups": [TEAM + ".*"]},
            {**entitlements, "com.apple.application-identifier": TEAM + ".another-app"},
        ]
        for invalid in invalid_cases:
            with self.assertRaises(MODULE.InvalidProfile):
                MODULE.validate_signature(payload, invalid, certificate, TEAM, NOW)
        with self.assertRaises(MODULE.InvalidProfile):
            MODULE.validate_signature(payload, entitlements, b"another-certificate", TEAM, NOW)

    def test_release_pipeline_requires_profile_and_explicit_final_entitlements(self):
        source = (ROOT / "scripts/build-release.sh").read_text()
        self.assertIn('DEVELOPER_ID_PROFILE must be set', source)
        profile_check = source.index('"$release_keychain_verifier" profile')
        cleanup = source.index('\nrelease_remove_generated_directory "$release_dir" "$archive_path"')
        self.assertLess(profile_check, cleanup)
        self.assertIn('--entitlements "$app_entitlements_path"', source)
        self.assertIn('"$staged_app/Contents/embedded.provisionprofile"', source)
        final_verifier = source[source.index('verify_signed_app_bundle()'):source.index('verify_bundle()')]
        self.assertIn('"$release_keychain_verifier" verify', final_verifier)
        final_check = source.index('verify_signed_app_bundle "$staged_app"')
        self.assertLess(final_check, source.index('remove_cli_build_root "$archive_path" "$cli_build_root"'))
        self.assertLess(final_check, source.index('"$hdiutil_path" create'))


if __name__ == "__main__":
    unittest.main()
