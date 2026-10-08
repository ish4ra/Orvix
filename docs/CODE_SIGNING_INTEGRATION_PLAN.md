# Windows code signing integration plan (SignPath)

**Status: planned, not implemented.** Orvix Windows releases are currently unsigned. Nothing in this document is active. This repository contains no SignPath workflow step, API token, organization ID, project slug, signing policy slug, or artifact configuration.

This is the plan to follow **after** SignPath Foundation approves Orvix and provides the real configuration. The rules it must respect are in [CODE_SIGNING_POLICY.md](../CODE_SIGNING_POLICY.md).

## 1. Values that only exist after approval

| Value | Where it will live |
|---|---|
| SignPath organization ID | GitHub environment variable `SIGNPATH_ORGANIZATION_ID` (not secret) |
| Project slug | environment variable `SIGNPATH_PROJECT_SLUG` |
| Signing policy slug (release signing) | environment variable `SIGNPATH_SIGNING_POLICY_SLUG` |
| Artifact configuration slugs (binaries, installer) | environment variables `SIGNPATH_ARTIFACT_CONFIG_BINARIES`, `SIGNPATH_ARTIFACT_CONFIG_INSTALLER` |
| API token of the SignPath CI submitter user | GitHub environment **secret** `SIGNPATH_API_TOKEN` |

All of them go into a GitHub **environment** named `signpath`, not into repository-wide secrets. The environment's deployment branch rule allows only `release/all-v*`. The repository keeps many historical branches with old workflows, so a repository-wide secret would be readable by any of them. An environment restricted to release branches is not.

## 2. One-time setup after approval

1. Turn on MFA for every team member's SignPath account. GitHub MFA must already be on.
2. Install the **SignPath GitHub App** on `ish4ra/Orvix` as SignPath's documentation describes.
3. In SignPath, link the project to the **GitHub.com trusted build system**. Origin verification then accepts only artifacts produced by GitHub Actions in this repository.
4. In the release signing policy:
   - restrict the source branches to `release/all-v*`;
   - require origin verification;
   - set the approvers to the Signing Approvers in `CODE_SIGNING_POLICY.md`, with manual approval on every request.
5. Create the two artifact configurations from section 4.
6. Create the `signpath` GitHub environment and its values from section 1.
7. Before the first signed release, land the binary metadata fixes from section 6 in a separate PR.

## 3. Workflow changes (`prerelease.yml`, Windows job only)

`ci.yml` never signs. Only the release workflow does. Every job up to and including signature verification keeps running on GitHub-hosted runners (`windows-latest`, `ubuntu-latest`), as SignPath requires for open-source projects.

Signing order inside the Windows job:

1. **Build** `orvix.exe` (Flutter) and `orvix-media-engine.exe` (Go), as today.
2. **Upload the unsigned Orvix binaries** as a workflow artifact that contains exactly those two files.
3. **Submit a signing request** for that artifact with the binaries artifact configuration, and wait for manual approval.
4. **Download the signed binaries** and **verify** them (section 5). Copy them over the unsigned files in `build\windows\x64\runner\Release`.
5. **Bundle third-party files unchanged:** FFmpeg tools, `orvix-stream-server.exe`, licenses. None of them is sent for signing.
6. Run the **existing smoke tests** (media engine, stream engine) against the signed build.
7. **Pack the portable ZIP**, which now contains the signed Orvix binaries.
8. **Build the installer** with Inno Setup from the signed files.
9. **Upload the unsigned installer** as its own workflow artifact.
10. **Submit a second signing request** with the installer artifact configuration, then download and verify the signed installer.
11. Run the **existing installer, updater handoff, and single-instance smoke tests** on the signed installer.
12. **Upload** the signed ZIP and signed installer as the `windows` artifact. The release job publishes them through `tools/publish_orvix_release.sh`, which already uploads to a draft and checks every expected asset before publishing.

Illustrative step shape. It is kept in this document on purpose, so it cannot run. Inputs must be re-checked against the SignPath documentation and the action's `action.yml` when it is implemented:

```yaml
  # Inside the Windows job of prerelease.yml, after "Build standalone Orvix media engine".
  # Job additions: `environment: signpath` and `permissions: { contents: read, actions: read }`.
      - id: upload-unsigned-binaries
        uses: actions/upload-artifact@v4
        with:
          name: windows-unsigned-binaries
          if-no-files-found: error
          path: |
            build/windows/x64/runner/Release/orvix.exe
            build/windows/x64/runner/Release/orvix-media-engine.exe

      - uses: signpath/github-action-submit-signing-request@<pinned release or commit>
        with:
          api-token: ${{ secrets.SIGNPATH_API_TOKEN }}
          organization-id: ${{ vars.SIGNPATH_ORGANIZATION_ID }}
          project-slug: ${{ vars.SIGNPATH_PROJECT_SLUG }}
          signing-policy-slug: ${{ vars.SIGNPATH_SIGNING_POLICY_SLUG }}
          artifact-configuration-slug: ${{ vars.SIGNPATH_ARTIFACT_CONFIG_BINARIES }}
          github-artifact-id: ${{ steps.upload-unsigned-binaries.outputs.artifact-id }}
          wait-for-completion: true
          wait-for-completion-timeout-in-seconds: 3600  # manual approval happens while this waits
          output-artifact-directory: signed-binaries
```

The installer step follows the same shape, using the installer artifact and `SIGNPATH_ARTIFACT_CONFIG_INSTALLER`.

Release notes: the "Windows code signing" block in the release job will switch from "not code signed" to a statement that the Windows files are signed, followed by the SignPath attribution. This happens only in the same change that turns signing on.

## 4. Artifact configurations

Each configuration lists **explicit file paths only**. It has no wildcards over directories, so a bundled third-party DLL or EXE can never match by accident. GitHub delivers workflow artifacts as ZIP archives, so the root element is a ZIP file.

Binaries (sketch, to be validated in SignPath's editor):

```xml
<artifact-configuration xmlns="http://signpath.io/artifact-configuration/v1">
  <zip-file>
    <pe-file path="orvix.exe">
      <authenticode-sign/>
    </pe-file>
    <pe-file path="orvix-media-engine.exe">
      <authenticode-sign/>
    </pe-file>
  </zip-file>
</artifact-configuration>
```

Installer: a ZIP containing one `pe-file` entry for `Orvix-Setup-v<version>-Windows-x64.exe` with `<authenticode-sign/>`. If SignPath's path matching needs it, use a file-name pattern limited to that single file.

Files that are deliberately **not** signed, as listed in `CODE_SIGNING_POLICY.md`:

- Flutter engine and plugin DLLs;
- libmpv, ANGLE, SwiftShader, Vulkan loader, `d3dcompiler_47.dll`;
- FFmpegKit and FFmpeg files;
- `orvix-stream-server.exe`;
- the Inno Setup uninstaller.

### Audit of Orvix-owned executables

Checked on `develop` when this plan was written:

| Executable | Orvix-owned? | Built in the release workflow? | Sign? |
|---|---|---|---|
| `orvix.exe` | yes | yes (`flutter build windows`) | **yes** |
| `orvix-media-engine.exe` | yes (`tools/orvix-media-engine`, Go standard library only) | yes | **yes** |
| `Orvix-Setup-v<version>-Windows-x64.exe` | yes (`installer/orvix.iss`) | yes | **yes** |
| `orvix-stream-server.exe` | MIT upstream plus Orvix patch | no. A prebuilt asset of the `stream-server-orvix-v0.1.8.3` release is downloaded | no, unless it is later built from source inside the signed workflow |
| `orvix_updater_helper.exe` | was shipped in old releases | no. `windows/runner/updater_helper.cpp` is not part of any build target | no |
| `unins000.exe` | Inno Setup runtime | generated by Inno Setup | no |
| Legacy Go prototype (`*.go` at the repository root) | yes | no, not part of any release | no |

## 5. Signature verification before publishing

For every signed file, on the Windows runner:

```powershell
$sig = Get-AuthenticodeSignature $file
if ($sig.Status -ne 'Valid') { throw "Signature of $file is $($sig.Status)" }
if ($sig.SignerCertificate.Subject -notmatch 'SignPath Foundation') {
  throw "Unexpected signer for ${file}: $($sig.SignerCertificate.Subject)"
}
if (-not $sig.TimeStamperCertificate) { throw "$file is not timestamped" }
```

The job also checks that the third-party files listed above are byte-identical to the files that were bundled. A failed check fails the Windows job, and the release job, which depends on it, never publishes.

## 6. Prerequisites in the binaries (separate PR before the first signed release)

- `windows/runner/Runner.rc` still carries Flutter template metadata: `CompanyName` "Orvix", `ProductName` "orvix", and a `LegalCopyright` naming `com.example`. Correct it to Orvix's real product name and copyright notice.
- `orvix-media-engine.exe` has no Windows version resource. Add one with product name, file description, and version.
- `installer/orvix.iss` should set the version info fields (`VersionInfoVersion`, `VersionInfoProductName`, `VersionInfoCompany`). The prerelease `AppVersion` (for example `0.7.9-beta.63`) is not a numeric file version.

These change the Windows build and must be validated through `ci.yml` and a prerelease like any other Windows change.

## 7. What does not change

- Asset names, tag format, installer `AppId`, install path, and the in-app updater's asset matching all stay the same. Signing only adds an Authenticode signature to the same files.
- Android, Android TV, and macOS builds are not affected.
