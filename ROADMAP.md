## Bring the reference console closer to Shorebird

The self-hosted server now ships a sidebar console (Overview / Patches / Telemetry / Settings) with rollout control, kill switch, per-patch download + apply-count adoption bars, and a 24h activity feed. This issue tracks closing the rest of the gap to a Shorebird-grade console.

### Done
- [x] Sidebar layout with Overview / Patches / Telemetry / Settings views
- [x] Overview metric cards (active patch, rollout %, patches, applies 24h, failures 24h)
- [x] Per-patch adoption bar (applies derived from telemetry) + patch.zip download
- [x] Telemetry tab with type filters
- [x] Live rollout slider + presets + channel, signed kill switch

### Remaining
- [ ] **Unique-device adoption** — telemetry has no `installId`, so "applies" counts events, not devices. Add an opt-in install id to `PatchEvent` and aggregate distinct devices per patch.
- [ ] **Adoption over time** — small chart of applies/failures per hour, like Shorebird's release adoption graph.
- [ ] **Multi-channel** — the store keeps a single `channel` string. Support stable/beta/staging with independent active patch + rollout each.
- [ ] **Rollout auto-halt** — watch the live patch's telemetry crash/failure rate and freeze (or revert) a rollout that crosses a threshold.
- [ ] **Admin auth** — the dashboard + write endpoints are unauthenticated. Add a token/login before it's reachable on a public URL.
- [ ] **Per-patch detail view** — drawer with full manifest, sha256, signature, ABIs, and the device-facing `/check` payload for that patch.

Server lives in `server/`. Dashboard is `server/src/dashboard.ts` (single embedded page, no build step).
