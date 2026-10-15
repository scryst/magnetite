# GitHub presence draft

For the integrator after review. Nothing here has been applied to GitHub.
Destinations verified read-only on 14 October 2026: `scryst/magnetite` is the
public source repository; `scryst/magnetite-releases` holds binaries and Pages.
The latest published release is v0.1.2. No new native release is proposed here.

## About

Source description:

> Free, open-source Spotify and Apple Music controls in your MacBook notch, with audio-reactive ferrofluid. macOS 26+, Apple silicon.

Releases description:

> Official downloads for Magnetite, the free Spotify and Apple Music notch player for macOS 26+ on Apple silicon. Source: scryst/magnetite.

Homepage for both: `https://magnetite.app`.

Keep the source's ten existing, accurate topics: `apple-music`,
`audio-visualizer`, `ferrofluid`, `macbook-notch`, `macos`, `music-player`,
`native-macos`, `spotify`, `swift`, `swiftui`. No invented popularity or CI badges.
The README release badge uses the releases repository, the actual binary authority.

## Social preview

Use the existing [site/og.png](../site/og.png), 1200 × 630, on both repositories.
It preserves the actual printed brand and readable wordmark. It is a branded
illustration, not a native screenshot; the README hero supplies the real app.
Keep the website's OG dimension and alt-text metadata matched to that file.

Upload manually in each repository's Settings → General → Social preview.
There is no supported `gh repo edit` social-preview-image flag; do not invent one
or automate a private upload API. No upload was performed in this lane.

## Community and releases

New local files: issue templates, PR template, [CONTRIBUTING.md](../CONTRIBUTING.md),
[SECURITY.md](../SECURITY.md) and a [release-notes template](../.github/RELEASE_TEMPLATE.md).
The release template is a maintainer starting point, not an automatically applied
GitHub release body. Replace every placeholder and use the signing status of the
actual artifact. A website/docs change alone does not call for a binary release.

The releases README should **share the pitch and install facts, not mirror the
whole source README**. Keep its role as a short download/verification index and
link to source docs for features, support and builds. The current release README
still hardcodes v0.1.1; the [replacement draft](RELEASES-README.md) uses `/latest`
and a version-independent checksum command to prevent that drift.

## Exact commands recommended after integration

These are a reviewable proposal, not a script to execute automatically. Run from
the integrated source checkout; verify the destination before each write.

```sh
gh repo view scryst/magnetite --json nameWithOwner,url,homepageUrl,repositoryTopics
gh repo view scryst/magnetite-releases --json nameWithOwner,url,homepageUrl,repositoryTopics
gh release view --repo scryst/magnetite-releases --json tagName,url,assets

gh repo edit scryst/magnetite --description 'Free, open-source Spotify and Apple Music controls in your MacBook notch, with audio-reactive ferrofluid. macOS 26+, Apple silicon.' --homepage 'https://magnetite.app'
gh repo edit scryst/magnetite --add-topic apple-music,audio-visualizer,ferrofluid,macbook-notch,macos,music-player,native-macos,spotify,swift,swiftui
gh repo edit scryst/magnetite-releases --description 'Official downloads for Magnetite, the free Spotify and Apple Music notch player for macOS 26+ on Apple silicon. Source: scryst/magnetite.' --homepage 'https://magnetite.app'

# Prepare an isolated release-index branch, then review its README diff.
gh repo clone scryst/magnetite-releases /tmp/magnetite-release-index-review -- --branch main --single-branch
git -C /tmp/magnetite-release-index-review switch -c docs/readme-1014
cp docs/RELEASES-README.md /tmp/magnetite-release-index-review/README.md
git -C /tmp/magnetite-release-index-review diff --check
git -C /tmp/magnetite-release-index-review diff -- README.md
git -C /tmp/magnetite-release-index-review add README.md
git -C /tmp/magnetite-release-index-review commit -m 'docs: clarify Magnetite downloads and support'
git -C /tmp/magnetite-release-index-review push origin docs/readme-1014
gh pr create --repo scryst/magnetite-releases --base main --head docs/readme-1014 --title 'Clarify downloads and link to current source docs' --body 'Replace the stale v0.1.1 install index with a latest-release link, checksum instructions, requirements and direct links to source support. No binaries or Pages branch changes.'
```

After the merged site candidate passes its gates, the integrator uses the
existing `./deploy.sh` workflow. Do not publish this worktree or run a bare Pages
upload. The native-app lane may change version/permissions: reconcile those facts
with its accepted commit before integrating this site's v0.1.2 claims.
