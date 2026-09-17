# Stable Local Code Signing Design

**Status:** Approved in conversation on 2026-09-11

## Goal

Sign local Codenotch Safe builds with the user's valid `Codenotch Local
Signing` identity so macOS can recognize successive builds by one stable
designated requirement. Keep GitHub Actions reproducible without copying the
private key into the repository or CI.

This change improves Keychain ACL continuity when the application is rebuilt
or reinstalled. It cannot prevent a new authorization prompt when Claude Code
replaces or rotates its own Keychain item.

## Signing modes

`Scripts/build-safe-local.sh` will select the signer before building the app:

1. If `CODENOTCH_SIGNING_IDENTITY` is set to `-`, use an explicitly requested
   ad-hoc signature.
2. If it names a 40-character certificate fingerprint, require that exact
   fingerprint to be present in the valid code-signing identities.
3. If it names an identity, require exactly one valid identity with that exact
   quoted name and use its fingerprint.
4. If it is unset, apply the same exact-name lookup to `Codenotch Local
   Signing`.

The GitHub Actions safe-verification step will explicitly set
`CODENOTCH_SIGNING_IDENTITY=-`. A local build will therefore fail with an
actionable error if the expected certificate is missing or ambiguous instead
of silently producing another ad-hoc build.

Identity resolution will be isolated from compilation and signing. A small
shell unit will parse supplied `security find-identity` output and return one
of three results: the unique fingerprint, no match, or an ambiguity error. The
build script will collect the live identity list and pass it to that unit. This
keeps certificate discovery testable without accessing a developer's
Keychain in CI.

## Build and evidence flow

The existing non-File-Provider staging flow remains in place. After compiling
the two executables, the build will:

1. resolve the signing mode;
2. copy the bundle to temporary staging and remove extended attributes;
3. sign the staged bundle with either the resolved fingerprint or explicit
   ad-hoc identity;
4. copy the sealed bundle back with `ditto --norsrc`;
5. record the selected mode and public fingerprint under the untracked
   `build/safe/verification` directory.

The private key and certificate contents will never be exported, printed, or
written into the repository.

`Scripts/verify-safe-local.sh` will continue strict deep signature and empty
entitlement checks. It will also save the signing authorities and designated
requirement as verification evidence. For a certificate-signed build it will
require the expected authority and reject a designated requirement based only
on a changing code-directory hash. For an explicitly ad-hoc build it will
record the ad-hoc result without claiming cross-build identity stability.

## Tests and failure behavior

Fixture-driven shell tests will cover:

- one exact default-name match;
- no match;
- duplicate exact-name matches;
- similarly named identities that must not match;
- an exact fingerprint override;
- a missing fingerprint override;
- explicit ad-hoc mode.

The tests will not query the real Keychain. `make safe-verify` will run them as
part of the safe build verification. Errors will state the requested identity
and the corrective action without printing unrelated identity names.

## Versioning, installation, and audit

The signed local build will become `1.6.0-safe.8` with bundle version `8`.
Before replacing `/Applications/Codenotch Safe.app`, the current safe.7 app
will be copied to `/Applications/Codenotch Safe.app.safe7-rollback` and its
existing signature will be verified. The safe.8 bundle will then be installed,
verified from `/Applications`, and launched.

Runtime validation will inspect only normalized provider status and process or
network behavior already inside the audited boundary. It will not print token
values, Keychain item contents, account identifiers, or raw provider response
bodies. If macOS asks for access to the current Claude credential, the user may
need to choose **Always Allow** once for the new stable signing identity.

`SECURITY-AUDIT.md` will record the new version, executable hashes, signing
authority, designated requirement, local verification result, installed-app
verification, and the distinction between the certificate-signed local build
and the ad-hoc CI artifact. The existing limits of the audit remain unchanged.
