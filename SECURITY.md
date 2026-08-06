# Security Policy

## Supported Versions

Security fixes target the latest stable QuickTTY release. Prerelease builds may receive fixes at the maintainers' discretion.

## Reporting a Vulnerability

QuickTTY does not currently have a private vulnerability-reporting channel.

Open a minimal [GitHub issue](https://github.com/dntsk/quicktty/issues/new) that states a security concern exists and identifies the affected QuickTTY version. **Do not include:**

- credentials, tokens, signing material, or personal data;
- working exploit code or detailed exploitation steps;
- private system information;
- terminal contents or configuration that may contain secrets.

A maintainer will use the issue to coordinate an appropriate next step. Public response or resolution timelines are not guaranteed.

For ordinary crashes, UI problems, and non-sensitive defects, use the [bug report form](https://github.com/dntsk/quicktty/issues/new?template=bug_report.yml).

## Scope

Useful reports identify behavior in QuickTTY itself, its bundled resources, or its integration with the pinned `libghostty`. Reports about upstream Ghostty that do not depend on QuickTTY should be sent to the upstream project according to its security policy.
