# Code signing policy

This policy describes how Orvix Windows binaries are, and will be, code signed.

## Current status

**Orvix Windows releases are currently unsigned.**

Orvix is **applying** to the [SignPath Foundation](https://signpath.org/) open-source code signing program. Orvix does not have a code signing certificate today. No Orvix release is SignPath-signed, and none should be described as signed until the application is approved and a signed release has actually been published and verified.

When that happens:

- this section will be updated with the first signed release;
- the release notes of every signed release will say explicitly that its Windows files are signed;
- the following attribution will apply to those signed releases. It does not apply to any release published before then:

> Free code signing provided by [SignPath.io](https://signpath.io), certificate by [SignPath Foundation](https://signpath.org)

Until then, Windows may show SmartScreen or "unknown publisher" warnings when you run the Orvix installer or `orvix.exe`. Signing helps Windows identify the publisher, but it does not guarantee that every SmartScreen reputation warning disappears immediately.

## Project

| | |
|---|---|
| Project | Orvix |
| Repository | https://github.com/ish4ra/Orvix |
| License | [AGPL-3.0-only](LICENSE) |
| Privacy policy | [PRIVACY.md](PRIVACY.md) |
| Third-party notices | [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) |

## Official artifacts

The only official Orvix downloads are the files attached to [GitHub Releases of ish4ra/Orvix](https://github.com/ish4ra/Orvix/releases). They are built and published by the repository's GitHub Actions release workflow (`.github/workflows/prerelease.yml`).

Files obtained anywhere else, including mirrors, re-uploads, or "repacks", are not official, even if they have the same name.

## Team roles

Orvix currently has a single maintainer, who holds every role:

| Role | Members |
|---|---|
| Committer / Author | [@ish4ra](https://github.com/ish4ra) |
| Reviewer | [@ish4ra](https://github.com/ish4ra) |
| Signing Approver | [@ish4ra](https://github.com/ish4ra) |

Outside contributions arrive as pull requests and are only merged after review by a Reviewer. Automated dependency pull requests (Renovate) go through the same review and CI. Automated review tools only assist the Reviewer and do not hold a role.

If more people join with write access to the repository or access to signing, this table will be updated before they take part in a signed release.

All members are expected to use multi-factor authentication for both their GitHub account and their SignPath account.

## What will be signed

Only files built by Orvix's GitHub Actions workflow from source code in this repository will be signed with the Orvix signing identity:

| File | Built from |
|---|---|
| `orvix.exe` | Flutter Windows runner and Dart code in this repository |
| `orvix-media-engine.exe` | Go source in `tools/orvix-media-engine` |
| `Orvix-Setup-v<version>-Windows-x64.exe` | Inno Setup script `installer/orvix.iss`, packaging the signed files above |

The portable ZIP contains the same signed `orvix.exe` and `orvix-media-engine.exe`. The ZIP file itself cannot carry an Authenticode signature.

## What will not be signed

Orvix packages contain third-party open-source components. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). **Upstream third-party DLLs and EXEs are never signed with the Orvix certificate just because they are bundled.** This includes, among others:

- the Flutter engine (`flutter_windows.dll`) and Flutter plugin DLLs;
- libmpv, ANGLE (`libEGL.dll`, `libGLESv2.dll`), SwiftShader, the Vulkan loader, Microsoft's `d3dcompiler_47.dll`, and the other media_kit native libraries;
- FFmpeg (`ffmpeg.exe`, `ffprobe.exe`) and the FFmpeg libraries bundled by FFmpegKit;
- `orvix-stream-server.exe`, an Orvix-patched build of the MIT-licensed upstream `stream-server`, which is built outside the release workflow;
- the Inno Setup uninstaller generated at install time.

Those files keep whatever signature (or lack of one) their upstream projects provide. The list of signed files will only grow if a new file is both Orvix-owned and built from this repository inside the signing workflow. Any such change will be made to this policy first.

## Build provenance

- Signing requests may only come from the `ish4ra/Orvix` repository, from a GitHub Actions workflow running on **GitHub-hosted runners**. Self-hosted runners and local machines are never used to produce files for signing.
- The files sent for signing are the exact workflow artifacts produced by that run. They are never uploaded by hand.
- Releases are only built from the repository's release branches, which are cut from `develop`. Historical branches are never used as a release source.

## Release and approval rules

- A signing request is only submitted after the release workflow's required validation has passed: static analysis, the full Flutter test suite, the media engine tests, and the Windows build and installer smoke tests.
- Every signing request needs manual approval in SignPath by a Signing Approver listed above. Approvers check that the request comes from the expected repository, branch, commit, and workflow run before approving.
- A release is published only after the signed files have been downloaded back into the workflow and their signatures have been verified.

## Verifying a signature

On Windows, in PowerShell:

```powershell
Get-AuthenticodeSignature .\Orvix-Setup-v<version>-Windows-x64.exe | Format-List
```

A signed file shows `Status : Valid` and a signer certificate issued to SignPath Foundation.

With the Windows SDK:

```powershell
signtool verify /pa /v .\Orvix-Setup-v<version>-Windows-x64.exe
```

You can also right-click the file, open **Properties**, and check the **Digital Signatures** tab.

Releases published before signing is in place have no signature, and these commands report them as unsigned (`NotSigned`).

## Incident response

If the signing identity, the build pipeline, the repository, or the provenance of a release is suspected to be compromised:

1. Stop approving signing requests immediately.
2. Investigate the affected workflow runs, commits, and releases.
3. Notify SignPath Foundation and work with them on revoking the certificate if needed.
4. Mark affected releases clearly on GitHub and tell users which files are affected.
5. Resume signing only after the cause has been identified and fixed.

To report a suspected compromise or a suspicious "Orvix" file, contact the maintainer [@ish4ra](https://github.com/ish4ra) on GitHub. Please do not post exploit details publicly.
