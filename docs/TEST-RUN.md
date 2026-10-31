# Testlauf – 3D Model Anything

**Datum:** 2026-10-29  
**Umgebung:** Linux-Container (kein Proxmox-Host), Node.js v22.23.2, npm 10.9.8

## Ergebnis

| Test | Befehl | Ergebnis |
|---|---|---|
| Shell-Syntax Installer | `bash -n install/3d-model-anything.sh` | OK |
| Shell-Syntax Smoke-Test | `bash -n tests/smoke.sh` | OK |
| ShellCheck | `shellcheck -x install/3d-model-anything.sh tests/smoke.sh` | OK (Exit 0) |
| Server-Tests | `node --test tests/*.test.js` | 13/13 pass |
| End-to-End-Smoke | `bash tests/smoke.sh` | Build 39 MB, Start + Neustart je HTTP 200 |

## End-to-End-Smoke (Build + Neustart-Simulation)

Der Smoke-Test lädt den gepinnten Upstream-Commit, baut ihn mit `npm ci &&
npm run build`, deployt `dist/` und `server/` in eine frische Verzeichnisstruktur
(wie im Container) und prüft Health, Startseite, `play.html` und ein
JavaScript-Bundle. Danach wird der Prozess per `SIGTERM` beendet und neu
gestartet.

Auszug aus `/tmp/3dma-smoke-final.log`:

```
[OK]    Build fertig (39M)
[SMOKE] Starte Static-Server auf http://127.0.0.1:5199 ...
[OK]    Erststart: /api/health = 200, Startseite + play.html + Bundle erreichbar
[SMOKE] Stoppe Prozess (Reboot-Simulation) ...
[SMOKE] Starte Prozess neu ...
[OK]    Nach Neustart: /api/health = 200, Startseite + play.html + Bundle erreichbar

[OK]    SMOKE-TEST BESTANDEN (Build + Serve + Neustart)
--- Server-Log (letzte 20 Zeilen) ---
[3d-model-anything] v1.0.0 serving /tmp/3dma-smoke-gLSKzM/site on http://127.0.0.1:5199
[3d-model-anything] received SIGTERM, shutting down
[3d-model-anything] v1.0.0 serving /tmp/3dma-smoke-gLSKzM/site on http://127.0.0.1:5199
```

## Server-Tests

```
# tests 13
# pass 13
# fail 0
```

Abgedeckt: `/api/health`, `index.html`, MIME-Typen (JS/GLB), 404,
Verzeichnis-Redirect, Path-Traversal, unerlaubte Methoden, HEAD,
Cache-Header für gehashte Assets und HTML.

## Echter LXC-Test (auf dem Proxmox-Host)

In dieser Umgebung gibt es kein `pct`/Proxmox, daher ist der echte
Container-Reboot hier nicht ausführbar. Auf dem Host:

```bash
bash 3d-model-anything.sh --ctid 150 --reboot-test
```

Erwartete Ausgabe (Auszug):

```
[OK]    Service läuft (systemctl is-active 3d-model-anything = active).
[OK]    Container-interner Health-Check: HTTP 200.
[OK]    Health-Endpunkt: HTTP 200 | Startseite: HTTP 200.
[INFO]  Reboot-Test: CT 150 wird neu gestartet ...
[OK]    Reboot-Test erfolgreich: Web UI nach Reboot erreichbar (HTTP 200).
```

Zusätzlich belegt `pct config 150` danach `onboot: 1`; der Dienst ist mit
`systemctl is-enabled 3d-model-anything` persistent aktiviert.

## Review-Fixes (Code-Review vom 2026-10-30)

Umgesetzt:
- `--dns` wird jetzt wirklich angewendet (`--nameserver` bei create/update).
- Symlink-Escape im Static-Server geschlossen (`realpath`-Containment-Check) + Tests.
- Dotfiles (`.env` etc.) werden nicht mehr ausgeliefert + Test.
- Root-Passwort wird direkt nach `pct create` angezeigt; Redaktion im ERR-Trap,
  falls ein Befehl das Passwort literal enthaelt.
- Update-Modus: Zusammenfassung zeigt echte CT-Konfiguration (`pct config`),
  Warnung, dass Ressourcen/Passwort im Update-Modus unveraendert bleiben.
- Storage-Auswahl nur ueber aktive Datastores (`pvesm status` Status-Spalte).
- Node-Mindestversion 22.12 (Vite-8-Anforderung) wird auf Host und im CT
  erzwungen; aeltere v22-Installs werden neu deployt.
- `/api/health`-Server beendet sich, wenn `dist/index.html` fehlt (Fail-fast).
- `--ssh-key` validiert Public-Key-Format und haengt an statt zu ueberschreiben.
- VM/CT-ID-Kollision wird erkannt; `require_value` lehnt Flag-Werte ab.
- Deploy-Heredoc ist jetzt single-quoted (keine Host-Expansion, Args via argv).
- systemd-Unit: APP_VERSION wird injiziert und auf Konsistenz geprueft.
- Response-Stream wird bei Client-Disconnect destroyed.

Bewusst nicht umgesetzt (niedrige Prioritaet, dokumentiert):
- Conditional-Requests (If-Modified-Since/304), CSP-Header, `tail`-Timing im
  ERR-Trap, `tar --mode` statt chmod-Nachlauf.
