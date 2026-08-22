# Matrica pokrivenosti Azure zahtjeva

Ova tablica služi kao kontrolna lista prije predaje. `Implementirano` znači da se zahtjev nalazi u IaC-u ili skripti; stvarni dokaz nastaje tek nakon uspješnog deploymenta u studentskoj pretplati i snimanja navedenog dokaza.

| Zahtjev iz projektnog zadatka | Status | Implementacija | Dokaz nakon deploymenta |
|---|---|---|---|
| Dvije Moodle aplikacijske instance po developeru | Implementirano | `modules/developer-workload.bicep`, petlja `appVms` | LB backend pool, oba health probea i Moodle u pregledniku |
| Aplikacijski VM ima 2 vCPU i 4 GB RAM-a | Implementirano | `Standard_B2s` | VM Size u Portalu i `test-deployment.ps1` |
| OS i dodatni podatkovni disk na svakom app VM-u | Implementirano | 32 GiB Standard SSD OS + data disk | VM Disks, `lsblk -f`, automatski test |
| Cloud distribucija Linuxa | Obrazloženo | Canonical Ubuntu 24.04 LTS zbog službene `azfilesauth` podrške | Image reference i obrazloženje u `ARCHITEKTURA.md` |
| Samo Jump Host ima javni IP | Implementirano | jedan Standard PIP na Jump NIC-u; svi ostali NIC-evi privatni | popis Public IP resursa i automatski test |
| Pristup aplikacijama samo preko Jump Hosta | Implementirano | interni LB, app NSG prihvaća HTTP/SSH samo iz huba | SSH tunnel, NSG pravila, izostanak javnih IP-eva |
| Zasebna mreža po developeru | Implementirano | zaseban RG, VNet, regija i subneti generirani po CSV retku | VNet/RG popis, regije i adresni prostori |
| Developer mreže međusobno izolirane | Implementirano | nema spoke-to-spoke peeringa; NSG + NVA private-range drop | `ISOLATION_PASS` i peering popis |
| VM-ovi imaju Internet egress | Implementirano | privatni subneti + UDR + Jump Linux NVA/SNAT | `curl` iz guest testa, route table i NVA pravila |
| Centralni Lead VM može SSH na sve app VM-ove | Implementirano | hub-spoke routing, app NSG iz huba, SSH agent forwarding | `ssh -A -J`, zatim SSH/`nc` prema sva četiri IP-a |
| Developer pali/gasi samo svoje VM-ove | Implementirano | postojeći developer korisnik i custom power rola na vlastitom RG scopeu | login kao developer: vlastiti Start/Deallocate radi, tuđi je odbijen |
| Lead pali/gasi sve VM-ove | Implementirano | postojeći Lead korisnik i ista minimalna rola na shared i svim developer RG-ovima | login kao Lead i power akcija u oba developer RG-a |
| Minimalna custom/built-in prava | Implementirano | custom VM power rola; ugrađene Blob i SMB MI data role | role definition, assignment scopeovi i automatizirani RBAC test |
| Object storage po developeru | Implementirano | zaseban Blob StorageV2 account i container | Storage popis, Blob container, `findmnt /mnt/moodleblob` |
| File storage po developeru | Implementirano | zaseban Azure Files account i share | Storage popis, File share, `findmnt /mnt/moodlebackup` |
| Oba storage tipa automatski montirana | Implementirano | BlobFuse2 MSI systemd mount + Azure Files SMB OAuth/MI mount | `findmnt`, `systemctl`, guest test |
| Least privilege i bez storage ključa | Implementirano | Shared Key disabled, firewall Default Deny, service endpoint, MI role scopeovi | Storage Networking/Configuration i MI role assignments |
| Load Balancer i usporedba s Application Gatewayem | Implementirano | interni Standard Load Balancer; tablica odluke u `ARCHITEKTURA.md` | LB frontend/backend/probe + dokumentacija |
| NSG i ASG | Implementirano | Jump/Lead/App/DB NSG-ovi te App/DB/Lead ASG-ovi | Portalna pravila i Bicep |
| Logička hijerarhija Resource Grupa | Implementirano | shared RG + developer RG po korisniku | RG popis, naming i RBAC scopeovi |
| Tagovi `project` i `environment` | Implementirano | prenose se svim resursima koji podržavaju tagove | tag prikaz i automatski test |
| Jedna CSV skripta, varijabilan broj korisnika | Implementirano | `scripts/deploy.ps1` + `ime;prezime;rola;upn;objectId` | jedan poziv skripte i subscription deployment |
| Najmanje 2 developera + 1 Lead | Validira se | skripta odbija manje od dva developera ili broj Leadova različit od jedan | primjer CSV-a i poruka validacije |
| Potpuni Infrastructure as Code | Implementirano | subscription-scope modularni Bicep + cloud-init + PowerShell orkestracija | Git repozitorij i uspješan deployment |
| Arhitekturni i RBAC dijagram | Implementirano | Mermaid izvori u `docs/` | renderirani dijagrami u predaji |
| Mjesečna procjena Azure troška | Implementirano | `TROSKOVI.md`, cijene i eksplicitne pretpostavke | tablica + ažurirani Pricing Calculator screenshot |
| Demonstracija i dokumentacija | Pripremljeno | `DOKAZI-I-VIDEO.md` | privatni/unlisted video, screenshotovi i Git povijest |

## Točke koje se ne smiju lažno označiti kao završene

- ARM `validate`, What-If i stvarni deployment ovise o prijavi, RBAC dozvolama, dostupnosti SKU-a i kvoti konkretne studentske pretplate.
- Entra korisnike nije moguće kreirati samo s Azure subscription `Owner` pravom; ograničeni fakultetski tenant koristi unaprijed pripremljene korisnike i njihove Object ID-eve.
- RBAC izolacija mora se dokazati stvarnim prijavama kao svaki testni korisnik, ne samo pregledom Bicepa.
- Cijene se moraju osvježiti neposredno prije predaje ako su se promijenile.
- Azure dio je ovdje dovršen; detaljna usporedna analiza i OpenStack implementacija rade se u sljedećoj fazi.
