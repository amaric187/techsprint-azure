# TechSprint - Azure dio projekta

Ovaj repozitorij implementira Azure polovicu projektnog zadatka iz kolegija "Implementacija racunarstva u oblaku". Rjesenje je namijenjeno Azure for Students pretplati, ali svjesno ne skriva stvarni trosak pune arhitekture.

Deployment se pokrece jednom PowerShell skriptom. Skripta prima putanju do CSV datoteke, kreira ili razrjesava Microsoft Entra korisnike, pretvara CSV u Bicep parametre te pokrece jedan subscription-scope Bicep deployment. RBAC se moze izravno dodijeliti postojecim korisnicima pa nisu potrebna prava za upravljanje Entra grupama.

## 1. Sto se kreira

Za test s dva developera i jednim DevOps Leadom nastaje:

- jedna zajednicka Resource Grupa s hub VNetom, Linux Jump/NVA VM-om i privatnim Lead VM-om;
- zasebna Resource Grupa (`dev01`, `dev02`, ...) i zaseban spoke VNet za svakog developera;
- dva Moodle aplikacijska VM-a `Standard_B2s` po developeru, svaki s OS i 32 GiB data Managed Diskom;
- jedan mali MariaDB VM `Standard_A1_v2` po developeru, jer Moodle ne moze raditi bez baze i DB mora koristiti odvojenu Av2 studentsku kvotu; za taj Gen1 VM koristi se Ubuntu 24.04 `server-gen1` slika;
- jedan interni Standard Load Balancer po developeru;
- jedan Blob Storage account i jedan Azure Files account po developeru;
- jedna user-assigned Managed Identity po developeru;
- BlobFuse2 mount objektnog spremista i SMB OAuth/Managed Identity mount Azure Files sharea;
- NSG-ovi, ASG-ovi, UDR-ovi, VNet peerinzi, custom Azure RBAC rola i role assignmenti;
- obavezni tagovi `project: techsprint` i `environment: testing` na svim resursima koji podrzavaju tagove.

Arhitektura je detaljno obrazlozena u [ARCHITEKTURA.md](docs/ARCHITEKTURA.md), a trosak u [TROSKOVI.md](docs/TROSKOVI.md).
Potpuna veza zahtjeva iz PDF-a s implementacijom i dokazima nalazi se u [MATRICA-BODOVANJA.md](docs/MATRICA-BODOVANJA.md).

## 2. Kljucevi ispravnosti dizajna

### Samo Jump Host ima javni IP

Developer i Lead VM-ovi nemaju javne IP adrese. Load Balanceri su interni. Moodle se otvara preko SSH local port forwarda kroz Jump Host.

Novi Azure subneti vise ne smiju ovisiti o implicitnom default outbound pristupu. Zato Jump Host ima ukljucen IP forwarding i radi kao kontrolirani Linux NVA/SNAT. UDR svakog spokea salje `0.0.0.0/0` na privatnu adresu Jump Hosta. Iptables dopusta Internet, ali odbacuje forwarded promet prema privatnim RFC1918 mrezama. To zadrzava izolaciju developera i izbjegava skupi Azure Firewall ili zaseban NAT Gateway za svaki VNet. Microsoft opisuje potrebu za eksplicitnim outbound pristupom u [Default outbound access dokumentaciji](https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/default-outbound-access).

### Azure Files bez storage kljuca

File Storage ima `SMBOAuth` ukljucen, Shared Key je iskljucen, a VM Managed Identity dobiva ugradenu rolu `Storage File Data SMB MI Admin`. Ubuntu 24.04 instalira `azfilesauth`, dohvat Kerberos/OAuth credentiala radi preko IMDS-a, a `azfilesrefresh` ga obnavlja. To je aktualni Microsoftov podrzani postupak: [Access SMB Azure file shares by using managed identities](https://learn.microsoft.com/en-us/azure/storage/files/files-managed-identities).

### Zasto Ubuntu 24.04, a ne Rocky Linux

Zadatak dopusta Rocky, CentOS Stream ili distribuciju specijaliziranu za cloud. Koristi se sluzbena Canonical Ubuntu 24.04 LTS Azure slika jer:

- nema dodatne Marketplace licence, sto je vazno jer Azure for Students kredit ne pokriva sve third-party Marketplace proizvode;
- `azfilesauth` je sluzbeno podrzan na Ubuntu 24.04;
- sadrzi Azure VM Agent i cloud-init te je optimizirana za Azure;
- PHP 8.3 i MariaDB 10.11 odgovaraju Moodleu 5.0.

Rocky se moze koristiti za osnovni VM, ali u trenutnoj Microsoftovoj dokumentaciji nije na popisu podrzanih Linux klijenata za Azure Files SMB Managed Identity mount. Odabir Rockyja uz storage key bio bi slabiji least-privilege odgovor.

## 3. Preduvjeti na Windows 11 racunalu

Pokrenite PowerShell kao obican korisnik i instalirajte:

```powershell
winget install Microsoft.AzureCLI
winget install Microsoft.PowerShell
winget install Git.Git
```

Zatvorite i ponovno otvorite PowerShell 7 (`pwsh`), zatim provjerite:

```powershell
az version
pwsh --version
git --version
ssh-keygen -h
```

Bicep instancom upravlja Azure CLI. Prije deploymenta provjerite `az bicep version`. Skripta ne radi automatsku nadogradnju usred deploymenta jer bi prekinuto preuzimanje moglo ostaviti neispravnu lokalnu Bicep instalaciju.

## 4. Azure for Students provjera prije deploymenta

Prijavite se i pronadite tocni Subscription ID:

```powershell
az login
az account list --output table
az account set --subscription "VAS-SUBSCRIPTION-ID"
az account show --output table
```

Za kreiranje infrastrukture i RBAC assignmenta korisnik treba `Owner` ili ekvivalent koji sadrzi `Microsoft.Authorization/roleAssignments/write`. `Contributor` sam nije dovoljan za role assignmente.

Za automatsko kreiranje Entra korisnika treba directory dozvola, tipicno `User Administrator` ili visa rola. Azure subscription `Owner` nije isto sto i Entra directory administrator.

Ako fakultetski tenant blokira kreiranje korisnika, koriste se postojeci korisnici:

1. nastavnik/tenant administrator daje testne korisnike ili potrebnu directory rolu;
2. koristi se tenant u kojem ste administrator i u njega se veže studentska pretplata, ako pravila pretplate to dopustaju;
3. pokrece se `Existing` mod nad unaprijed kreiranim testnim korisnicima; njihovi Object ID-evi mogu se navesti u CSV-u kada tenant blokira directory read.

Bez odvojenih Entra principalova nije moguce vjerodostojno dokazati da developer moze paliti samo svoje VM-ove. Nemojte sva tri retka CSV-a mapirati na isti account.

Na provjerenoj Azure for Students pretplati dostupno je 6 ukupnih i 4 B-series vCPU-a po dopustenoj regiji. Zato je zadani raspored: shared u `switzerlandnorth`, dev01 u `francecentral`, dev02 u `norwayeast`. Svaka developer regija koristi 4 B-series jezgre za dva B2s app VM-a i 1 Av2 jezgru za A1_v2 DB. Skripta provjerava samo dodatnu kvotu potrebnu za VM-ove koji jos ne postoje, pa se djelomicni deployment moze sigurno nastaviti.

## 5. Priprema CSV-a

### Create mod - skripta kreira Entra korisnike

Datoteka je UTF-8 i koristi tocku-zarez:

```csv
ime;prezime;rola;upn;objectId
Ana;Anic;devops_lead;;
Luka;Lukic;developer;;
Iva;Ivic;developer;;
```

`upn` moze ostati prazan. Skripta koristi `<ime>-<prezime>@<TenantDomain>`.

### Existing mod - korisnici vec postoje

```csv
ime;prezime;rola;upn;objectId
Ana;Anic;devops_lead;ana.anic@algebra.hr;11111111-1111-1111-1111-111111111111
Luka;Lukic;developer;luka.lukic@algebra.hr;22222222-2222-2222-2222-222222222222
Iva;Ivic;developer;iva.ivic@algebra.hr;33333333-3333-3333-3333-333333333333
```

`objectId` je opcionalan ako `az ad user show --id <UPN>` radi. U ogranicenom fakultetskom tenant-u preporucuje se upisati ga kako deployment ne bi trebao citati Entra direktorij. Object ID nije lozinka ni tajna. Ne koristiti administratorski `Owner` racun kao Lead jer bi naslijedena Owner prava pokvarila least-privilege dokaz.

Podrzane role su tocno `developer` i `devops_lead`. Mora postojati tocno jedan Lead i najmanje dva developera. Jedna skripta obraduje varijabilni broj developera; adresni plan podrzava do 28.

## 6. Jedan deployment poziv

Iz korijena repozitorija:

```powershell
Set-ExecutionPolicy -Scope Process Bypass

.\scripts\deploy.ps1 `
  -SubscriptionId "00000000-0000-0000-0000-000000000000" `
  -CsvPath ".\data\users.example.csv" `
  -IdentityMode Create `
  -TenantDomain "vas-tenant.onmicrosoft.com" `
  -Location "switzerlandnorth" `
  -DeveloperLocations "francecentral","norwayeast"
```

Ako koristite postojece korisnike:

```powershell
.\scripts\deploy.ps1 `
  -SubscriptionId "00000000-0000-0000-0000-000000000000" `
  -CsvPath ".\data\users.existing.csv" `
  -IdentityMode Existing `
  -Location "switzerlandnorth" `
  -DeveloperLocations "francecentral","norwayeast"
```

Prije prvog stvarnog deploymenta preporucuje se besplatna validacija. Koristi iste
parametre, ali nista ne stvara:

```powershell
.\scripts\deploy.ps1 `
  -SubscriptionId "00000000-0000-0000-0000-000000000000" `
  -CsvPath ".\data\users.existing.csv" `
  -IdentityMode Existing `
  -Location "switzerlandnorth" `
  -DeveloperLocations "francecentral","norwayeast" `
  -ValidationOnly
```

Kopirajte `data\users.existing.example.csv` u `data\users.existing.csv` i zamijenite primjer stvarnim UPN/Object ID vrijednostima. Datoteka `users.existing.csv` je lokalni ulaz i ne treba sadrzavati lozinke.

Skripta automatski:

1. provjerava Azure CLI, prijavu i Subscription ID;
2. registrira potrebne resource providere;
3. validira CSV, broj rola i jedinstvena imena;
4. kreira korisnike ili razrjesava postojece korisnike iz UPN/Object ID stupaca;
5. generira SSH kljuc ako ne postoji;
6. ogranicava SSH prema trenutno otkrivenoj javnoj adresi `/32`;
7. provjerava vCPU quota;
8. kompilira Bicep i radi ARM validate;
9. prikazuje Azure What-If;
10. pokrece jedan `az deployment sub create` i u terminalu prikazuje aktivnu fazu;
11. prati jednostavne Moodle bootstrap faze (`paketi`, `Blob mount`, `Azure Files`, `Moodle`, `spremno`) bez ispisa velikog Azure JSON-a;
12. kod greske sprema detalje u `output/bootstrap-diagnostics.json`;
13. zapisuje pristupne naredbe u `output/deployment-summary.json`.

Moodle bootstrap ne blokira provisioning VM-a ni Azure Custom Script ekstenziju.
Kratki cloud-init launcher i ekstenzija pokrecu isti idempotentni pozadinski
worker, a `deploy.ps1` zasebno prati marker i fazu svakog VM-a. Time se izbjegava
fiksni timeout ekstenzije i korisnik u terminalu vidi sto se priblizno dogada.

Ako je okolina nastala starijom verzijom skripte koja je BlobFuse2 servis
postavila kao `Type=forking`, popravak se moze pokrenuti bez ponovne izgradnje
VM-ova:

```powershell
.\scripts\repair-app-bootstrap.ps1 -SubscriptionId $SubscriptionId
```

`Location` je regija shared huba. `DeveloperLocations` je uredena lista: prva regija pripada prvom developeru u CSV-u, druga drugom developeru itd. Regije moraju imati dovoljno odvojenih quota limita.

Tajne i inicijalne lozinke spremaju se samo lokalno u `output/`, koji je u `.gitignore`. Ne snimajte lozinke u video i ne commitajte ih.

## 7. Pristup Moodleu i VM-ovima

Na kraju deploymenta skripta ispisuje tocne naredbe. Primjer za prvi Moodle:

```powershell
ssh -N -L 8080:10.20.1.10:80 azureadmin@JUMP_PUBLIC_IP
```

Dok je SSH prozor otvoren, u pregledniku otvorite:

```text
http://localhost:8080
```

Za drugi developer environment port je 8081. Load Balancer IP je privatan i nije dostupan izravno s Interneta.

Pristup Lead VM-u:

```powershell
# Za sljedeća dva retka prvi put otvorite PowerShell kao Administrator.
Get-Service ssh-agent | Set-Service -StartupType Manual
Start-Service ssh-agent
ssh-add "$HOME\.ssh\techsprint_azure_ed25519"
ssh -A -J azureadmin@JUMP_PUBLIC_IP azureadmin@10.0.1.4
```

Opcija `-A` prosljedjuje lokalni SSH agent u Lead sesiju, pa Lead VM moze autentificirano pristupiti svim aplikacijskim VM-ovima bez kopiranja privatnog kljuca na Azure VM. Agent forwarding koristite samo prema ovom kontroliranom Lead Hostu.

Iz Lead VM-a:

```bash
ssh azureadmin@10.20.1.11
ssh azureadmin@10.20.1.12
ssh azureadmin@10.21.1.11
ssh azureadmin@10.21.1.12
```

## 8. Automatizirano testiranje

Nakon deploymenta:

```powershell
.\scripts\test-deployment.ps1 `
  -SubscriptionId "00000000-0000-0000-0000-000000000000"
```

Test provjerava Resource Grupe, tagove, samo jedan public IP, B2s velicine, OS+data diskove, interne Load Balancere, Storage firewall/Shared Key, SMB OAuth, mountove, Internet egress, zabranu dev-to-dev komunikacije i Lead-to-app pristup. JSON rezultat se sprema u `output/`.

Uz automatizirane testove obavezno napravite portalne RBAC testove prijavom kao svaki testni korisnik. Detaljan popis screenshotova i video scena je u [DOKAZI-I-VIDEO.md](docs/DOKAZI-I-VIDEO.md).

## 9. Gasenje i trosak

`Stop` u guest OS-u nije dovoljan; VM mora biti `Stopped (deallocated)` da prestane compute naplata. Diskovi, Load Balancer i public IP i dalje se naplacuju.

Za potpuno uklanjanje nakon dokaza:

```powershell
.\scripts\destroy.ps1 `
  -SubscriptionId "00000000-0000-0000-0000-000000000000"
```

Skripta prikazuje tocne Resource Grupe i zahtijeva tekstualnu potvrdu. Ne brise nista izvan `rg-techsprint-tst-*` grupa s oba projektna taga. Nakon potvrde prati brisanje i uklanja projektnu custom rolu kada Resource Grupe nestanu.

## 10. Git tijek

Nemojte predati repozitorij s jednim zavrsnim commitom. Predlozeni ritam:

```powershell
git init
git add .
git commit -m "docs: define Azure architecture and naming convention"

git add .
git commit -m "feat: add hub spoke networking and jump NVA"

git add .
git commit -m "feat: add Moodle compute load balancer and storage"

git add .
git commit -m "feat: automate CSV identities and least privilege RBAC"

git add .
git commit -m "test: add deployment verification and cost estimate"
```

Dodajte vlastiti udaljeni Git repozitorij i redovito pushajte. Datoteke `generated/` i `output/` namjerno se ne commitaju.

## 11. Poznata granica simulacije HA

Dva Moodle web noda i Load Balancer simuliraju visoku dostupnost aplikacijskog sloja. MariaDB je namjerno jedan mali VM po developeru jer zadatak ne zahtijeva HA baze, a studentski kredit je ogranicen. To nije potpuna produkcijska HA arhitektura. Produkcijska verzija koristila bi Azure Database for MySQL Flexible Server s HA ili Galera cluster te pouzdaniji shared filesystem/cache. BlobFuse2 takoder nije potpuna POSIX zamjena; ovdje sluzi za trazeni laboratorijski object-storage mount.
