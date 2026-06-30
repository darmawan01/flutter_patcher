# Shipping patches from CI

Once your app is wired up ([getting started](getting-started.md)) and your server is
running, shipping a hot-patch is a single command — so it drops straight into CI/CD.
Your pipeline builds the release APK and runs `flutter_patcher:release`, which packs,
uploads, and (optionally) makes the patch live.

> A patch only changes **Dart code** (and Flutter assets) and must target the
> **versionCode of the build already on devices**. CI ships patches *between* store
> releases — it doesn't replace your store release pipeline.

## What CI needs

Two secrets (GitHub → Settings → Secrets and variables → Actions):

| Secret | What it is |
|---|---|
| `FP_SERVER` | your server base URL, e.g. `https://you.up.railway.app` |
| `FP_ADMIN_TOKEN` | the server's admin token (same value as the server's `FP_ADMIN_TOKEN`) |

And two values the job must get right:

- **`--target-version-code`** — the versionCode of the app build your users are running
  (the baseline the patch upgrades *from*). Hardcode it per release line, or read it from
  your `pubspec.yaml` / a release manifest.
- **`--patch-number`** — strictly increasing; the device refuses anything ≤ the last applied.
  `github.run_number` works, or keep a counter.

## Example: GitHub Actions

Trigger it manually (or on a `patch-*` tag) so you choose when to ship. Full file:
[`examples/ship-patch.yml`](examples/ship-patch.yml).

```yaml
name: Ship hot-patch
on:
  workflow_dispatch:
    inputs:
      version: { description: 'Patch version (e.g. 1.4.0-h1)', required: true }
      target_version_code: { description: 'versionCode the patch targets', required: true }
      rollout: { description: 'Rollout %', default: '10' }
      channel: { description: 'Channel (blank = default)', default: '' }

jobs:
  ship:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with: { channel: stable }
      - run: flutter pub get
      # Catch wiring mistakes before building.
      - run: dart run flutter_patcher:doctor --project .
      - run: flutter build apk --release
      - name: Pack, upload, and make live
        env:
          FP_SERVER: ${{ secrets.FP_SERVER }}
          FP_ADMIN_TOKEN: ${{ secrets.FP_ADMIN_TOKEN }}
        run: |
          dart run flutter_patcher:release \
            --apk build/app/outputs/flutter-apk/app-release.apk \
            --server "$FP_SERVER" --token "$FP_ADMIN_TOKEN" \
            --version "${{ inputs.version }}" \
            --target-version-code "${{ inputs.target_version_code }}" \
            --patch-number "${{ github.run_number }}" \
            ${{ inputs.channel && format('--channel {0}', inputs.channel) || '' }} \
            --rollout "${{ inputs.rollout }}" --make-live
      - name: Confirm what the server is serving
        run: dart run flutter_patcher:status --server "${{ secrets.FP_SERVER }}" ${{ inputs.channel && format('--channel {0}', inputs.channel) || '' }}
```

`release` and `status` exit non-zero on failure, so a bad upload or wrong token fails
the job instead of silently passing.

## Patterns

- **Stage, then widen.** Ship at `--rollout 10`, watch the dashboard's failures /
  **Devices 24h** / auto-halt, then re-run (or bump rollout in the dashboard) to 100%.
- **Channels.** Push to `--channel beta` first; promote to the default channel once it's
  clean. See [getting started → Channels](getting-started.md#channels-stable--beta--staging).
- **Auto-halt as a safety net.** Turn on rollout auto-halt in the server's Settings so a
  bad patch freezes itself even if no one is watching the pipeline.
- **Delta patches.** Add `--from-apk <baseline.apk>` to ship a binary diff (much smaller).
  Cache the baseline APK as a CI artifact.

## GitLab / others

Any runner works — it's just `flutter build apk` + `dart run flutter_patcher:release`.
Put `FP_SERVER` / `FP_ADMIN_TOKEN` in the runner's protected variables and call the same
two commands.
