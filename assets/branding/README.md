# Mobdev identity

The abstract folded **m** brings several connected modules into one mark. It represents Mobdev
as an all-in-one toolkit for mobile development, testing, automation and device management.
The blue version is the product identity; amber identifies the separate development app.

`mobdev.png` and `mobdev-dev.png` are the original transparent PNG masters created with the
built-in Imagegen tool on 2026-09-30. The exact generation prompts are in `prompts.md`.
All exports retain the generated artwork; there is no separate hand-drawn approximation.

Regenerate from the repository root on macOS:

```sh
swift macos/scripts/make-icon.swift macos/Resources/AppIcon.png
swift macos/scripts/make-icon.swift --dev macos/Resources/AppIconDev.png
bun --cwd cloud run og-image
```

The web export needs the cloud dependencies and Google Chrome (or `CHROME=/path/to/chrome`).
It writes `cloud/public/logo.png` (128 px), `app-icon.png` (512 px), `favicon.png` (32 px),
`favicon.svg` (a self-contained PNG wrapper at the existing URL), `apple-touch-icon.png`
(180 px, opaque) and `og.png` (1200 × 630 px). The Mac exports are 1024 px with transparent
padding; `macos/scripts/build-app.sh` packages them into the app's ICNS.

The normal Cloud and Mac app workflows publish the exported assets on a push to `main`.
Regeneration does not change WorkOS's separately uploaded branding settings.
