# SkyLab Proxmox VE Installer

Ein Install-Script im Stil der Proxmox-Helper-Scripts: Es erstellt auf einem
Proxmox-VE-Host einen Debian-LXC, installiert Docker und richtet
[SkyLab](https://github.com/SkyLab-tw/SkyLab) ein – die selbstgehostete
Campus-Cloud für VMs, Klassen und Proxmox-Verwaltung.

- Erstellt einen **unprivilegierten LXC** (Debian 13, Fallback Debian 12)
- Ressourcen: **2 vCPU / 4 GB RAM / 20 GB Disk** (anpassbar)
- Docker + Docker Compose im Container
- SkyLab unter `/opt/skylab`, Start über Docker Compose
- Generierte Secrets und Zugangsdaten unter `/root/skylab-<CTID>.creds`
- Update-Helfer `skylab-update` im Container

## Voraussetzungen

- Proxmox VE **8 oder neuer**
- Root-Zugriff auf den PVE-Host
- Internetzugang im Container (APT, Docker Hub, GitHub)
- Template-Storage (`vztmpl`) und RootFS-Storage (`rootdir`) konfiguriert
- Optional: statische IP mit passendem Gateway

## Installation (Einzeiler)

Auf dem **Proxmox-Host als root**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/SkySchoolProxmoxLab/main/skylab-install.sh)"
```

Mit Parametern (das erste Argument nach dem Script ist `$0`, danach folgen die Optionen):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/SkySchoolProxmoxLab/main/skylab-install.sh)" skylab --ip 10.0.0.50/24 --gw 10.0.0.1
```

Alternativ erst herunterladen und prüfen:

```bash
curl -fsSL -o /tmp/skylab-install.sh https://raw.githubusercontent.com/HatchetMan111/SkySchoolProxmoxLab/main/skylab-install.sh
less /tmp/skylab-install.sh
bash /tmp/skylab-install.sh
```

Oder aus einem lokalen Checkout:

```bash
git clone https://github.com/HatchetMan111/SkySchoolProxmoxLab.git
cd SkySchoolProxmoxLab
bash skylab-install.sh
```

## Optionen

| Option | Bedeutung | Default |
| --- | --- | --- |
| `--ctid <id>` | Container-ID | nächste freie ID |
| `--hostname <name>` | Container-Hostname | `skylab` |
| `--ip <dhcp\|CIDR>` | Netzwerk, z. B. `10.0.0.50/24` | `dhcp` |
| `--gw <ip>` | Gateway bei statischer IP | – |
| `--bridge <bridge>` | Netzwerk-Bridge | `vmbr0` |
| `--dns <ip>` | DNS-Server im Container | `1.1.1.1` |
| `--storage <storage>` | Storage für das RootFS | automatisch |
| `--disk <gb>` | Disk-Größe in GB | `20` |
| `--cores <n>` | CPU-Kerne | `2` |
| `--memory <mb>` | RAM in MB | `4096` |
| `--swap <mb>` | Swap in MB | `512` |
| `--port <port>` | SkyLab-Webport | `8082` |
| `--admin-email <mail>` | Bootstrap-Admin | `admin@example.com` |
| `--admin-password <pw>` | Admin-Passwort | generiert |
| `--root-password <pw>` | Root-Passwort des Containers | generiert |
| `--privileged` | privilegierten Container erstellen | unprivileged |
| `-h`, `--help` | Hilfe anzeigen | – |

Beispiele:

```bash
# statische IP, mehr Platz und RAM
bash skylab-install.sh --ip 10.0.0.50/24 --gw 10.0.0.1 --disk 30 --memory 8192

# eigene CTID, anderer Port, eigener Admin
bash skylab-install.sh --ctid 120 --port 8080 --admin-email admin@schule.example
```

## Nach der Installation

1. Im Browser `http://<container-ip>:8082/setup` öffnen.
2. Setup-Wizard ausfüllen: Administrator → Proxmox-Verbindung → IP-Subnetz →
   optional Gateway/HTTPS.
3. Templates aus cloud-init-fähigen VMs erstellen und Rollen
   (`student` / `teacher` / `admin`) vergeben.

Zugangsdaten liegen auf dem PVE-Host unter `/root/skylab-<CTID>.creds`
(alternativ: `pct exec <CTID> -- cat /root/skylab.creds`).

```bash
pct enter <CTID>                      # Shell im Container
pct exec <CTID> -- skylab-update      # SkyLab aktualisieren
```

### Setup-Wizard: Proxmox VE verbinden

Im Schritt **"Connect the first Proxmox VE"** trägst du den Zugang zu deinem
Proxmox-Server ein. Die SkyLab-Instanz spricht PVE über die API an – sie muss
den Host also selbst erreichen können.

| Feld | Was eingeben |
| --- | --- |
| **Host** * | IP-Adresse oder DNS-Name des PVE-Knotens bzw. Cluster-Einstiegspunkts, z. B. `192.168.1.10` oder `pve.school.edu`. **Ohne** `https://` und **ohne** `:8006` – der Port hat ein eigenes Feld. |
| **Port** | `8006` (PVE-API), nur ändern wenn dein PVE anders lauscht |
| **API user** * | `root@pam` oder ein eigener PVE-Benutzer, z. B. `skylab@pve` |
| **Password** * | Passwort dieses PVE-Benutzers (API-Token werden hier nicht unterstützt) |
| **API timeout** | `30` Sekunden passt meist |
| **Verify the TLS certificate** | aus lassen, wenn PVE ein Self-Signed-Zertifikat nutzt; bei privater CA ankreuzen und das CA-Zertifikat als PEM einfügen |

Danach **Test connection** klicken. Erst wenn der Test grün ist, kannst du die
erkannten Nodes/Storages als Defaults übernehmen:

- **Resource pool name:** `SkyLab` (Pool vorher in PVE anlegen oder Default lassen)
- **Default node:** automatisch oder einen Knoten wählen
- **ISO storage:** z. B. `local`
- **Disk storage:** z. B. `local-lvm`

Wichtig:

- Der Host muss **aus dem SkyLab-Container** erreichbar sein, nicht nur von
  deinem Laptop. Kurz prüfen:
  `pct exec <CTID> -- curl -k https://<host>:8006`
- Bei einem **Cluster** reicht ein beliebiger Knoten als Host; der Test erkennt
  den Cluster und listet alle Nodes.
- Der PVE-Benutzer braucht Rechte zum Klonen/Erstellen/Starten/Stoppen/Löschen
  von VMs und LXC sowie zum Lesen von Nodes und Storages. `root@pam` funktioniert;
  sauberer ist ein eigener Benutzer mit z. B. der Rolle `PVEAdmin` auf `/`.
- Nutzt `root@pam` Zwei-Faktor-Authentifizierung, besser einen eigenen
  PVE-Benutzer ohne TFA anlegen.
- Die Zugangsdaten werden verschlüsselt in der SkyLab-Datenbank gespeichert.
  Deshalb `SECRET_KEY` in `/opt/skylab/.env` später nicht einfach ändern.

### Setup-Wizard: IP-Subnetz

Im nächsten Schritt legst du fest, aus welchem Netz die VMs/LXC ihre festen
IPs bekommen:

| Feld | Beispiel |
| --- | --- |
| **Subnet CIDR** | `10.10.0.0/24` |
| **Gateway IP** | `10.10.0.1` |
| **PVE bridge name** | `vmbr1` (die Bridge, an der die Maschinen hängen) |
| **VLAN ID** | optional, z. B. `100` |
| **Gateway VM IP** | `10.10.0.2` (nur nötig, wenn du die Gateway-VM nutzt) |
| **Main system IP** | optional, z. B. `10.10.0.3` |
| **DNS servers** | optional, z. B. `8.8.8.8,1.1.1.1` |

Gateway- und Gateway-VM-IP müssen im Subnetz liegen und sich unterscheiden.
Das Subnetz muss auf der gewählten PVE-Bridge geroutet sein.

## Was das Script macht

1. Prüft PVE-Version, Storage und Template-Verfügbarkeit.
2. Lädt bei Bedarf das Debian-Template herunter.
3. Erstellt und startet den LXC (`nesting=1`, `keyctl=1`, `fuse=1`, `onboot=1`).
4. Installiert im Container Docker und Docker Compose.
5. Klont SkyLab nach `/opt/skylab` und erzeugt `.env` mit generierten Secrets.
6. Baut und startet den Stack ohne LiteLLM (`--scale litellm=0`).
7. Wartet auf den Backend-Health-Check und schreibt die Zugangsdaten.

## Hinweise

- **Kein KI-Stack und kein Gateway:** LiteLLM/vLLM und die Debian-13-Gateway-VM
  werden nicht installiert. Beides lässt sich später laut
  [SkyLab-Doku](https://docs.skylab-tw.com) ergänzen.
- **Docker im unprivilegierten LXC:** Das Script setzt die nötigen Features und
  fällt bei Bedarf auf den `vfs`-Storage-Treiber zurück. Falls Docker trotzdem
  nicht startet, Container mit `--privileged` neu erstellen.
- **20 GB Disk** sind für den ersten Build knapp bemessen; bei vielen Images
  besser `--disk 30` oder mehr.
- **DHCP:** `FRONTEND_HOST` wird beim Installieren auf die aktuelle IP gesetzt.
  Ändert sich die IP später, muss der Wert in `/opt/skylab/.env` angepasst werden.

## Fehlersuche

```bash
pct status <CTID>
pct exec <CTID> -- docker compose -f /opt/skylab/docker-compose.yml ps
pct exec <CTID> -- docker compose -f /opt/skylab/docker-compose.yml logs --tail=100 backend
```

Bei einem Fehler bleibt der Container zum Debuggen stehen:

```bash
pct enter <CTID>
pct stop <CTID> && pct destroy <CTID>   # komplett entfernen
```

## Lizenz

Dieses Install-Script steht unter der MIT-Lizenz. SkyLab selbst ist
AGPL-3.0-lizenziert.
