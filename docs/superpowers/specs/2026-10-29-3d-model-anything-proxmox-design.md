# 3D Model Anything – Proxmox-LXC-Installer

**Datum:** 2026-10-29  
**Status:** Approved  
**Repo:** <https://github.com/HatchetMan111/3DModelScanner-Proxmox>  
**Upstream:** <https://github.com/wesbos/3d-model-anything> (Commit `31b2dc9da3fb541e501f2f0936e55b32afb70ee8`)

## Ziel

Der Three.js-Raumviewer von `wesbos/3d-model-anything` soll sich auf einem
Proxmox-VE-Host mit einem Einzeiler im Stil der Proxmox-VE-Community-Scripts
als lokaler LXC installieren lassen. Die Weboberfläche läuft vollständig lokal,
startet nach einem Reboot automatisch und benötigt zur Laufzeit keine Cloud.

Die iPhone-Capture-App ist nicht Bestandteil des Containers. Der Container
liefert den Viewer inklusive der mitgelieferten Office-Demo.

## Entscheidungen

| Thema | Entscheidung | Begründung |
|---|---|---|
| Virtualisierung | LXC (keine VM) | Statischer Viewer, kein GPU-/Kernel-Bedarf; Community-Scripts-Stil |
| Build-Ort | Proxmox-Host | Im Container kein `apt`, `npm` oder DNS nötig; kleiner Footprint |
| Laufzeit | Node.js 22 + dependency-freier Static-Server | Kein `node_modules` im Container, reproduzierbar |
| Upstream | gepinnter Commit, per `--upstream-ref` überschreibbar | Reproduzierbare Builds |
| Port | 5188 (Upstream-Default), per `--port` änderbar | Kompatibel zum Upstream-Viewer |
| CT-Ressourcen | 2 vCPU / 1024 MB / 8 GB Disk | Host baut; 8 GB für spätere eigene Captures |
| Service-User | `modelanything` | Linux-Usernamen dürfen nicht mit einer Ziffer beginnen |
| Template | Debian 12 standard, unprivilegiert, `nesting=1`, `onboot=1` | Standard der Community Scripts |

## Architektur

```
Proxmox-Host                                LXC (Debian 12)
────────────                                ───────────────
pveam / pct create  ──────────────────────► CT <nächste freie ID>
Node-22-Tarball     ── entpacken ──► /tmp
Upstream-Tarball    ── npm ci ─────► /tmp
                    ── npm run build
dist/               ── pct push ──────────► /opt/3d-model-anything/dist
server/server.js    ── pct push ──────────► /opt/3d-model-anything/server
Node-Runtime        ── pct push ──────────► /opt/node
systemd-Unit        ── pct push ──────────► /etc/systemd/system/…service
                                            systemd: modelanything, :5188
```

### Komponenten

- `install/3d-model-anything.sh` – Orchestrierung, Argumente, Fehlerkette.
- `server/server.js` – statischer Server, `/api/health`, Pfad-Traversal-Schutz,
  MIME- und Cache-Header, `0.0.0.0:${PORT}`.
- `systemd/3d-model-anything.service` – `Restart=always`,
  `After/Wants=network-online.target`, moderate Sandbox-Härtung.
- `tests/server.test.js` – `node:test` für Health, Static, 404, Traversal,
  Methoden und Cache-Header.
- `tests/smoke.sh` – lokaler End-to-End-Beweis: Upstream bauen, servieren,
  Prozess stoppen/neu starten (Reboot-Simulation), erneut prüfen.

## Schnittstellen

### HTTP

| Route | Verhalten |
|---|---|
| `GET /api/health` | `200` + JSON `{status:"ok", app, version, uptimeSeconds}` |
| `GET /<pfad>` | Datei aus `dist/`, Verzeichnisse → `index.html` |
| `HEAD` | Wie `GET`, ohne Body |
| andere Methoden | `405` |
| unbekannt | `404` |

### Installer-Optionen

`--ctid`, `--hostname`, `--cores`, `--memory`, `--disk`, `--storage`,
`--template-store`, `--bridge`, `--dns`, `--password`, `--ssh-key`,
`--port`, `--upstream-repo`, `--upstream-ref`, `--local-src`, `--local-repo`,
`--reboot-test`, `--debug`, `--help`.

`--local-src` zeigt auf einen lokalen Upstream-Checkout (App-Quelle);
`--local-repo` auf einen lokalen Checkout dieses Installer-Repos
(`server/` und `systemd/` statt GitHub-Raw-Download).

## Fehlerbehandlung

- `set -euo pipefail`, `ERR`-Trap mit Befehl, Zeile und Exit-Code.
- Vollständiges Log unter `/tmp/3d-model-anything-install-<zeit>.log`.
- Bei Service-/HTTP-Fehler: `systemctl status`, `journalctl -n 100`,
  `ss -ltnp`, Verzeichnis-Listing, Node-/User-Prüfung.
- `--debug` aktiviert `bash -x` inklusive Datei/Zeile im Log.
- Idempotent: existierender CT → Update-Modus, Datenverzeichnis bleibt erhalten.

## Verifikation

1. `bash -n` und `shellcheck` für das Install-Script.
2. `npm test` (Server-Tests).
3. `tests/smoke.sh` baut den Upstream, startet den Server, prüft Health und
   Startseite, beendet den Prozess, startet ihn neu und prüft erneut.
4. Auf dem Proxmox-Host: Installation mit `--reboot-test`; das Script rebootet
   den CT und prüft `/api/health` erneut. Der erwartete Ablauf steht im README.

## Nicht im Scope

- iOS-App, LiDAR-Capture und Xcode-Build.
- Upload/Import eigener Scans über die Weboberfläche.
- TLS/Reverse-Proxy, Authentifizierung, Mehrbenutzerbetrieb.
- Verteilung der Upstream-Assets: Der Installer lädt sie zur Installationszeit
  von Upstream. Es gilt `ASSETS-LICENSE.md` des Upstream-Repos.

## Akzeptanzkriterien

- Einzeiler installiert ohne manuelle Schritte einen laufenden LXC.
- `http://<CT-IP>:5188/` liefert die Viewer-Oberfläche, `/api/health` `200`.
- `systemctl is-active 3d-model-anything` ist `active`; `onboot=1` gesetzt.
- Nach `pct reboot` ist die Oberfläche ohne Eingriff wieder erreichbar.
- Fehlerausgaben enthalten die vollständige Kette und den Logpfad.
