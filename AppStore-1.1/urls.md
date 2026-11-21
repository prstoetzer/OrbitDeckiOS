# App Store Connect URLs (OrbitDeck 1.1)

Domain from `docs/CNAME`: `orbitdeckios.n8hm.radio` (GitHub Pages, served from `docs/`).

| Field (App Store Connect) | URL | Page in repo | Exists |
|---|---|---|---|
| Support URL (required, per version) | https://orbitdeckios.n8hm.radio/documentation.html | `docs/documentation.html` | yes |
| Marketing URL (optional, per version) | https://orbitdeckios.n8hm.radio/ | `docs/index.html` | yes |
| Privacy Policy URL (App Information, required) | https://orbitdeckios.n8hm.radio/privacy.html | `docs/privacy.html` | yes |

Notes

- **Support URL choice.** Apple requires the support URL to lead to a way to get help. `documentation.html` is the most useful landing page; the only direct contact on the site is the email in `privacy.html` ("Contact": n8hm@arrl.net). If you want a page with visible contact info, either use the privacy page, the GitHub repository's Issues page (https://github.com/prstoetzer/OrbitDeckiOS/issues, from the README's PR links; confirm Issues are enabled), or add a short "Support / contact" line to `documentation.html` before submitting (another agent is editing `docs/` now, so coordinate). Not changed here.
- `privacy.html` is dated November 21, 2026 and already covers Open-Meteo, APRS-IS, the satgate, DX cluster, ADS-B, status.amsat.org, the rigctld/rotctld servers, voice memos and on-device DeepCW. Make sure the updated `docs/` is pushed and live on GitHub Pages **before** you submit, because App Review opens these URLs.
- Check each URL in a browser after pushing (HTTPS certificate valid, page loads, no 404).
- Other pages also present in `docs/`: catcontrol.html, rotator.html, digitalmodes.html, logging.html, source.html, tinybasic.html, ft4-ic9700-network.html.
