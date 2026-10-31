# 3D Model Anything – Proxmox LXC

Lokaler Three.js-Raumviewer auf Basis von
[wesbos/3d-model-anything](https://github.com/wesbos/3d-model-anything),
installierbar als Proxmox-LXC im Stil der
[Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE/).
Kein Docker, keine Cloud, kein Konto: Der Container liefert den Viewer inklusive
Office-Demo im eigenen LAN.

## Projekt

| Feld | Wert |
|---|---|
| **App-Name** | 3D Model Anything |
| **Zweck** | Three.js-Viewer für aus iPhone-LiDAR-Scans rekonstruierte Räume |
| **Tech-Stack** | Node.js 22, Vite/Three.js (Build auf dem Host), systemd |
| **Upstream** | <https://github.com/wesbos/3d-model-anything> (gepinnter Commit) |
| **Installer-Repo** | <https://github.com/HatchetMan111/3DModelScanner-Proxmox> |
| **Web-UI-Port** | `5188` (Bind: `0.0.0.0`, per `--port` änderbar) |
| **Virtualisierung** | LXC (statischer Viewer, keine GPU/VM nötig) |

## Einzeiler-Installation auf Proxmox

Voraussetzungen:

- Proxmox VE 8.x mit root-Zugriff
- Internetzugang auf dem Host (Template, Node.js, Upstream-Quelle)
- RootFS-Storage (bevorzugt `local-lvm`, alternativ z. B. `local`)
- Ein Debian-12-LXC-Template (der Installer lädt es bei Bedarf)
- Mindestens 2 GB freier Platz in `/tmp` auf dem Host (Build-Cache)

Auf dem **Proxmox-Host**:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/3DModelScanner-Proxmox/main/install/3d-model-anything.sh)"
```

Der Installer wählt automatisch die nächste freie CT-ID, erstellt einen
unprivilegierten LXC (`onboot=1`, `nesting=1`), baut den Viewer auf dem Host und
deployt nur das fertige `dist/` plus Node.js und den Static-Server in den
Container. Im Container werden weder `apt` noch `npm` oder DNS benötigt.

Mit Optionen (Beispiel):

```bash
wget -O 3d-model-anything.sh \
  https://raw.githubusercontent.com/HatchetMan111/3DModelScanner-Proxmox/main/install/3d-model-anything.sh
bash 3d-model-anything.sh --ctid 150 --cores 2 --memory 1024 --disk 8 --bridge vmbr0
```

### Optionen

| Option | Default | Bedeutung |
|---|---|---|
| `--ctid ID` | nächste freie ID | Container-ID |
| `--hostname NAME` | `3d-model-anything` | Hostname des Containers |
| `--cores N` | `2` | vCPUs |
| `--memory MB` | `1024` | RAM in MB |
| `--disk GB` | `8` | Disk in GB |
| `--storage NAME` | auto (`local-lvm`) | RootFS-Storage |
| `--template-store NAME` | `local` | Storage für LXC-Templates |
| `--bridge NAME` | `vmbr0` | Netzwerk-Bridge |
| `--dns IP` | automatisch | DNS im Container |
| `--password PW` | zufällig | Root-Passwort (wird angezeigt) |
| `--ssh-key PATH` | – | SSH-Public-Key für root |
| `--port N` | `5188` | Web-UI-Port (1024–65535) |
| `--upstream-repo URL` | wesbos-Repo | Andere Upstream-Quelle |
| `--upstream-ref REF` | gepinnter Commit | Commit/Tag/Branch |
| `--installer-ref REF` | `main` | Ref dieses Repos für `server/` und `systemd/` (zum Pinning eine Commit-SHA setzen) |
| `--local-src PATH` | – | Lokaler Upstream-Checkout statt Download |
| `--local-repo PATH` | – | Lokaler Checkout dieses Repos (`server/`, `systemd/`) |
| `--reboot-test` | aus | CT nach Installation rebooten und erneut prüfen |
| `--debug` | aus | `bash -x` plus vollständige Fehlerkette |
| `-h`, `--help` | – | Hilfe |

Umgebungsvariablen funktionieren analog: `CT_ID`, `CORES`, `RAM`, `DISK`,
`BRIDGE`, `DNS`, `STORAGE`, `PASSWORD`, `SSH_KEY`, `PORT`,
`UPSTREAM_REPO_ARG`, `UPSTREAM_REF_ARG`, `INSTALLER_REF_ARG`, `LOCAL_SRC`,
`LOCAL_REPO`, `REBOOT_TEST`, `DEBUG`.

## Was der Installer macht

1. Prüft Host, Argumente, Storage und Template (`pveam`).
2. Legt den LXC an oder geht bei vorhandener CT-ID in den Update-Modus.
3. Lädt Node.js 22 und die gepinnte Upstream-Quelle auf den Host.
4. Baut den Viewer hostseitig mit `npm ci && npm run build`.
5. Deployt `dist/`, `server/server.js` und die systemd-Unit in den Container.
6. Richtet den Service-User `modelanything` ein, aktiviert und startet den Dienst.
7. Prüft `systemctl is-active`, `/api/health` und `/` – intern und von außen.

## Verifikation

Am Ende gibt der Installer aus:

```
════════════════ INSTALLATION ERFOLGREICH ════════════════
  App           : 3D Model Anything
  Container     : CT 150 (3d-model-anything, unprivilegiert, onboot=1)
  Ressourcen    : 2 vCPU / 1024 MB RAM / 8 GB Disk
  Endpoint      : http://192.168.1.50:5188
  Health        : http://192.168.1.50:5188/api/health
  ...
```

Manuell prüfen:

```bash
curl -fsS http://<CT-IP>:5188/api/health
# {"status":"ok","app":"3d-model-anything","version":"1.0.0","uptimeSeconds":3}
```

### Reboot-Test

Der Installer kann den Reboot selbst prüfen:

```bash
bash 3d-model-anything.sh --ctid 150 --reboot-test
```

Erwartete Ausgabe (Auszug):

```
[INFO]  Reboot-Test: CT 150 wird neu gestartet ...
[OK]    Reboot-Test erfolgreich: Web UI nach Reboot erreichbar (HTTP 200).
```

Manuell:

```bash
pct reboot 150
sleep 30
curl -fsS http://<CT-IP>:5188/api/health
```

## Update

Den Installer erneut mit derselben CT-ID ausführen. Der Container bleibt
bestehen, `/var/lib/3d-model-anything` bleibt erhalten, Build und Deploy werden
erneuert:

```bash
bash 3d-model-anything.sh --ctid 150
```

Anderen Upstream-Stand testen:

```bash
bash 3d-model-anything.sh --ctid 150 --upstream-ref main
```

## Deinstallation

```bash
pct stop 150
pct destroy 150
```

Das löscht den Container und damit auch `/var/lib/3d-model-anything`.

## Fehlersuche

Bei jedem Fehler gibt das Script die komplette Kette aus: fehlgeschlagenen
Befehl, Zeile, Exit-Code, Logpfad sowie `systemctl status`, `journalctl -n 100`
und offene Ports. Zusätzlich:

```bash
bash 3d-model-anything.sh --ctid 150 --debug
```

Das erzeugt ein `bash -x`-Log unter `/tmp/3d-model-anything-install-*.log`.
Häufige Ursachen:

| Symptom | Ursache / Lösung |
|---|---|
| `pct`/`pveam` nicht gefunden | Auf dem Proxmox-Host ausführen, nicht im Container |
| Kein Template gefunden | `pveam update` prüfen, Template-Store prüfen |
| Kein RootFS-Storage | `--storage local-lvm` oder vorhandenen Storage angeben |
| Build scheitert | Host-Internet und `/tmp`-Platz prüfen; `--debug` zeigt npm-Ausgabe |
| HTTP 000 von außen | Proxmox-Host-Firewall oder falsche Bridge prüfen |
| Port belegt | `--port <frei>` verwenden (Update installiert die Unit neu) |

Der Dienst läuft als `modelanything` (kein root). Die Unit nutzt
`Restart=always`, `After=network-online.target` und moderate Sandbox-Härtung.

## Lokale Entwicklung

```bash
npm test              # Server-Tests (node:test)
bash tests/smoke.sh   # Upstream bauen, servieren, Neustart simulieren
```

Der Smoke-Test benötigt Node.js >= 22.12, `npm`, `curl` und Internet. Er belegt
den Ablauf „Build → Web UI erreichbar → Prozess-Neustart → Web UI erreichbar“
mit Logausgabe. Ein echter LXC-Reboot ist nur auf einem Proxmox-Host möglich
(`--reboot-test`).

## Scope und Grenzen

- Der Container liefert den **Viewer**. Die iPhone-App zum Scannen ist eine
  iOS-App und wird nicht im LXC installiert.
- Eigene Räume werden über den Upstream-Workflow (`data/captures-in/…`,
  `demos/`) eingebunden und erfordern einen Rebuild:
  `--local-src /pfad/zum/checkout`.
- Kein Login, kein TLS, kein Reverse-Proxy: nur im vertrauenswürdigen LAN/VPN
  betreiben.
- Die Office-Demo wird aus dem Upstream-Repo geladen. Für Bilder/Texturen gilt
  die dortige `ASSETS-LICENSE.md`; der Installer verteilt sie nicht weiter.

## Lizenz

Der Code dieses Installers und des Static-Servers ist MIT-lizenziert
(siehe `LICENSE`). Der Upstream-Code ist ebenfalls MIT. Der zur Laufzeit
ausgelieferte Build (`dist/`) enthält zusätzlich Three.js (MIT) und
`@dimforge/rapier3d-compat` (Apache-2.0) - bei Weiterverteilung des Builds
gelten deren Lizenzbedingungen inklusive Apache-2.0-Hinweispflicht. Die
mitgelieferten Bilder/Texturen unterliegen separaten Bedingungen.
