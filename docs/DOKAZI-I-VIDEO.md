# Dokazi, screenshotovi i scenarij videa

Nemojte snimiti samo Resource Group overview. Svaki screenshot treba dokazati jednu konkretnu stavku bodovanja i imati citljiv naziv resursa, scope ili rezultat naredbe.

## Preporuceni screenshotovi

| Datoteka | Sto mora biti vidljivo | Bodovna stavka |
|---|---|---|
| `01-subscription-deployment-success.png` | Subscription deployment, status Succeeded, trajanje i naziv | Automatizacija bez gresaka |
| `02-resource-groups.png` | Shared RG i po jedan RG za svakog developera | Logicka RG hijerarhija |
| `03-tags.png` | `project=techsprint`, `environment=testing` na reprezentativnim resursima | Tagiranje |
| `04-architecture.png` | Renderirani Azure dijagram | Azure arhitektura |
| `05-rbac-diagram.png` | Renderirani RBAC dijagram | Azure RBAC model |
| `06-vnets.png` | Hub i dva odvojena developer VNeta s address spaceovima | VNet po korisniku |
| `07-peerings.png` | Hub-spoke peerinzi bez spoke-spoke peeringa | Izolacija |
| `08-public-ip-only-jump.png` | Popis project public IP resursa, samo Jump PIP | Samo Jump javno dostupan |
| `09-jump-nsg.png` | SSH/22 samo s vaseg `/32` | Jump sigurnost |
| `10-app-db-nsg-asg.png` | App/DB NSG pravila i source/destination ASG | NSG i ASG |
| `11-route-table.png` | `0.0.0.0/0 -> Virtual appliance 10.0.0.4` | Internet egress postavke |
| `12-load-balancer.png` | Internal frontend, backend pool s dva NIC-a, healthy probe | Load Balancer |
| `13-app-vm-size-disks.png` | B2s, OS disk i data disk na app VM-u | 2 vCPU/4 GB i dva diska |
| `14-storage-accounts.png` | Blob i File account po developeru | Objektna/datotecna pohrana |
| `15-storage-firewall.png` | Default Deny, dopusten tocni VNet/subnet, Shared Key disabled | Least privilege |
| `16-managed-identity-rbac.png` | MI role na Blob containeru i File accountu | Managed Identity |
| `17-mounts.png` | `findmnt /mnt/moodleblob /mnt/moodlebackup` i `lsblk -f` | Automatski mountovi |
| `18-moodle-node-a.png` | Moodle preko tunela i `/health.html` ili node identitet app1 | Moodle instanca 1 |
| `19-moodle-node-b.png` | Backend ili test koji potvrduje app2 u poolu | Moodle instanca 2 |
| `20-dev-own-power.png` | Developer login, vlastiti VM Start/Deallocate dostupan | Developer power prava |
| `21-dev-denied-other-rg.png` | Isti developer nema dozvolu nad tudim VM-om | RBAC izolacija |
| `22-lead-all-power.png` | Lead vidi i moze upravljati VM-ovima u oba developer RG-a | Lead prava |
| `23-lead-ssh-all.png` | Lead VM `nc`/SSH prema sva cetiri app IP-a | Lead SSH pristup |
| `24-dev-network-denied.png` | test-deployment `ISOLATION_PASS` | Dev VNet izolacija |
| `25-cost-calculator.png` | Switzerland North, France Central i Norway East stavke te mjesecni total | Procjena troska |
| `26-test-results.png` | Svi automatizirani testovi PASS | Implementacija/testiranje |

Prije screenshotova sakrijte Subscription ID, tenant ID, javni IP ako dokument ide javno, sve lozinke, SSH private key i generirane secret datoteke.

## Rucne dokazne naredbe na app VM-u

```bash
hostname
lsblk -f
findmnt /srv/moodle
findmnt /mnt/moodleblob
findmnt /mnt/moodlebackup
systemctl is-active moodleblob
systemctl is-active azfilesrefresh
systemctl is-active apache2
curl -I https://packages.microsoft.com
curl http://127.0.0.1/health.html
```

## RBAC test kao developer

1. Otvorite InPrivate/Incognito prozor.
2. Prijavite se kao prvi developer s inicijalnim UPN-om.
3. Otvorite vlastiti RG i napravite `Stop`/`Start` ili `Deallocate`/`Start` na vlastitom app VM-u.
4. Izravnim URL-om ili pretragom pokusajte otvoriti VM drugog developera.
5. Snimite poruku `You do not have authorization` ili nedostupnu akciju.
6. Ponovite s drugim developerom.

Samo `Reader` nije dokaz. Mora se vidjeti da power akcija na vlastitom VM-u radi, a na tudem ne radi.

## RBAC test kao Lead

1. Prijavite se kao DevOps Lead.
2. Pokazite VM-ove iz shared i oba developer RG-a.
3. Izvrsite `Restart` nad po jednim VM-om iz obje developer okoline.
4. Spojite se na privatni Lead VM kroz Jump Host.
5. Iz Lead VM-a provjerite TCP/22 ili SSH prema sva cetiri app VM-a.

## Scenarij privatnog YouTube videa

Preporuceno trajanje: 12-18 minuta.

1. **Uvod (1 min):** cilj, Azure for Students, broj korisnika u CSV-u.
2. **CSV i jedna skripta (1 min):** pokazite `users.csv` i `deploy.ps1`; objasnite da jedna invokacija radi identity + jedan Bicep deployment.
3. **Bicep moduli (2 min):** main, hub, developer network, workload, RBAC; pokazite naming i tag parametre.
4. **Pokretanje (2-4 min, moze ubrzano):** prikaz numeriranih terminalskih faza, validate, sazetog What-If pregleda, Moodle faze `spremno` i finalni `Succeeded`. Ne pokazujte lozinke.
5. **Arhitektura (2 min):** hub-spoke, Jump/NVA, interni LB, dva app noda, DB, Blob i Files.
6. **Mreza (2 min):** peerinzi, UDR, NSG/ASG i samo jedan public IP.
7. **Storage (2 min):** storage firewall, Managed Identity RBAC, `findmnt` i `azfilesrefresh`.
8. **IAM/RBAC (2 min):** CSV postojeci korisnici, custom rola, izravni user scopeovi, own-vs-other developer test i Lead test.
9. **Moodle i HA simulacija (1 min):** tunel, aplikacija, LB backend health.
10. **Test skripta i trosak (1-2 min):** PASS rezultat, mjesecna procjena i objasnjenje zasto odmah gasite/brisete.

Video postavite kao **Private** samo ako nastavniku mozete eksplicitno dati pristup njegovom Google racunu. Ako nastavnik trazi link bez dodavanja racuna, u praksi je potreban **Unlisted**. Provjerite tocnu uputu s nastavnikom prije predaje.

## Nakon snimanja

Ako nastavniku vise ne trebaju zivi resursi, pokrenite `destroy.ps1`. Sacuvajte screenshot deploymenta, JSON test rezultat, dijagrame, dokumentaciju i Git povijest. Ne oslanjajte se na to da ce Azure resursi ostati dostupni nakon isteka studentskog kredita.
