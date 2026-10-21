// Version ordering for the Control Center.
//
// App versions follow pubspec's `X.Y.Z-stage.N+BUILD`; release tags are `v`
// plus the version without `+BUILD`. Prerelease identifiers compare the
// SemVer way: numeric parts numerically (beta.9 < beta.10 < beta.100), text
// parts lexically (alpha < beta < rc), and a release ranks above any of its
// prereleases (0.7.10-beta.4 < 0.7.10).

export type ParsedVersion = {
  core: number[];
  prerelease: (number | string)[];
  build: string | null;
};

const versionRe =
  /^v?(\d+(?:\.\d+){0,3})(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?$/;

export function parseVersion(value: unknown): ParsedVersion | null {
  if (typeof value !== "string") return null;
  const match = versionRe.exec(value.trim());
  if (!match) return null;
  const core = match[1].split(".").map((part) => Number(part));
  while (core.length < 3) core.push(0);
  const prerelease = match[2]
    ? match[2].split(".").filter(Boolean).map((part) =>
      /^\d+$/.test(part) ? Number(part) : part.toLowerCase()
    )
    : [];
  return { core, prerelease, build: match[3] ?? null };
}

function compareIdentifiers(a: number | string, b: number | string): number {
  if (typeof a === "number" && typeof b === "number") return a - b;
  if (typeof a === "number") return -1;
  if (typeof b === "number") return 1;
  return a < b ? -1 : a > b ? 1 : 0;
}

/// Ascending comparison. Unparseable versions sort below every real version
/// and among themselves by plain text, so they stay visible but never jump
/// ahead of a real release.
export function compareVersions(a: unknown, b: unknown): number {
  const pa = parseVersion(a);
  const pb = parseVersion(b);
  if (!pa || !pb) {
    if (pa) return 1;
    if (pb) return -1;
    return String(a ?? "").localeCompare(String(b ?? ""));
  }

  const length = Math.max(pa.core.length, pb.core.length);
  for (let i = 0; i < length; i++) {
    const diff = (pa.core[i] ?? 0) - (pb.core[i] ?? 0);
    if (diff !== 0) return diff;
  }

  if (!pa.prerelease.length && pb.prerelease.length) return 1;
  if (pa.prerelease.length && !pb.prerelease.length) return -1;
  const pre = Math.max(pa.prerelease.length, pb.prerelease.length);
  for (let i = 0; i < pre; i++) {
    if (pa.prerelease[i] === undefined) return -1;
    if (pb.prerelease[i] === undefined) return 1;
    const diff = compareIdentifiers(pa.prerelease[i], pb.prerelease[i]);
    if (diff !== 0) return diff;
  }
  return 0;
}

/// Version without `+BUILD` and without a leading `v`, as used in tags.
export function versionKey(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim().replace(/^v/i, "");
  if (!trimmed) return null;
  return trimmed.split("+")[0];
}

export function isPrereleaseVersion(value: unknown): boolean {
  return (parseVersion(value)?.prerelease.length ?? 0) > 0;
}
