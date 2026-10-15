# Contributing to Magnetite

Small, focused fixes and useful bug reports are welcome. Start with the
[README](README.md), [design principles](PRODUCT.md) and [how the app is built](APP.md).
Discuss larger features in an issue before investing in an implementation.

## Report a bug

Use the [issue tracker](https://github.com/scryst/magnetite/issues). Include:

- Magnetite version, macOS version, Mac model and display/notch setup.
- Spotify or Music, and whether the problem occurs while playing or paused.
- Steps, what you expected and what happened.
- A cropped screenshot or short recording when helpful.

Remove account names, private music, tokens and unrelated desktop content.
Never attach your Application Support folder. Send security reports privately
as described in [SECURITY.md](SECURITY.md).

## Make a change

1. Fork and create a focused branch. Use macOS 26+, Apple silicon and Command
   Line Tools for native changes; Node.js runs the site checks.
2. Keep the diff small and in line with the design principles in PRODUCT.md.
3. For logic changes, add a test. Run `./check.sh` before opening the PR. See
   [engineering notes](docs/ENGINEERING.md) for running single checks.
4. For UI changes, attach before/after screenshots or a short recording. For
   the website, check it at 1280px and 390px wide, by keyboard and with Reduce
   Motion on.
5. In the PR, say what changed for the user and how you tested it.

Do not include credentials, generated build folders or unrelated formatting.
Release assets and deployment are maintained separately; a PR should not
publish them. Contributions are licensed under the repository's [MIT licence](LICENSE).
