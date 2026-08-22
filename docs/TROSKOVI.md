# Procjena mjesecnih Azure troskova

Datum izracuna: **21. kolovoza 2026.** Regije: **Switzerland North, France Central i Norway East**. Valuta: **USD**, PAYG retail, bez PDV-a. Cijene su dohvaćene iz sluzbenog [Azure Retail Prices API-ja](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices) i trebaju se ponovno provjeriti neposredno prije predaje.

## Pretpostavke

- 730 sati mjesecno, svi VM-ovi i Load Balanceri aktivni cijeli mjesec.
- 2 developera i 1 DevOps Lead.
- Po developeru: 2 x B2s app VM, 1 x A1_v2 DB VM, 1 interni Standard LB.
- Shared: 1 x B1s Jump/NVA i 1 x B1s Lead VM.
- 14 x Standard SSD E4 LRS diskova od 32 GiB: 8 OS + 6 data.
- 20 GB Blob i 20 GB Azure Files stvarno zauzeto po developeru.
- 20 GB mjesecnog LB obradjenog prometa ukupno.
- 40 GB ukupno naplativog intra-region peering ingress/egress prometa.
- 1 milijun Standard SSD transakcija ukupno.
- 100.000 Blob write i 1.000.000 Blob read operacija.
- Azure Files transakcije procijenjene na 0,25 USD.
- Internet egress je zanemariv/ispod ukljucene besplatne kolicine; backup, Defender for Cloud i Log Analytics nisu ukljuceni jer se ne deployaju.

## Izracun

| Stavka | Kolicina | Jedinicna cijena | Formula | Mjesecno USD |
|---|---:|---:|---:|---:|
| Linux VM `Standard_B2s` | 2 France + 2 Norway | 0,0472 / 0,0528 USD/sat | 2 x 730 x 0,0472 + 2 x 730 x 0,0528 | 146,00 |
| Linux VM `Standard_B1s` | 2 Switzerland | 0,0132 USD/sat | 2 x 730 x 0,0132 | 19,27 |
| Linux VM `Standard_A1_v2` | 1 France + 1 Norway | 0,0500 / 0,0451 USD/sat | 730 x 0,0500 + 730 x 0,0451 | 69,42 |
| Standard SSD E4 LRS 32 GiB | 2 Switzerland + 12 France/Norway | 2,88 / 2,64 USD/mj | 2 x 2,88 + 12 x 2,64 | 37,44 |
| Standard Load Balancer, ukljucena pravila | 2 | 0,025 USD/sat | 2 x 730 x 0,025 | 36,50 |
| Standard static IPv4 | 1 | 0,005 USD/sat | 730 x 0,005 | 3,65 |
| Blob Hot LRS kapacitet | 40 GB | 0,0196 USD/GB-mj | 40 x 0,0196 | 0,78 |
| Azure Files Standard LRS kapacitet | 40 GB | 0,06 USD/GB-mj | 40 x 0,06 | 2,40 |
| LB obradjeni podaci | 20 GB | 0,005 USD/GB | 20 x 0,005 | 0,10 |
| Global VNet peering | 40 GB | 0,035 USD/GB | 40 x 0,035 | 1,40 |
| Standard SSD transakcije | 1.000.000 | 0,0026 USD/10k | 100 x 0,0026 | 0,26 |
| Blob write operacije | 100.000 | 0,054 USD/10k | 10 x 0,054 | 0,54 |
| Blob read operacije | 1.000.000 | 0,0043 USD/10k | 100 x 0,0043 | 0,43 |
| Azure Files transakcije | procjena | - | pretpostavka | 0,25 |
| **Ukupno** |  |  |  | **318,44 USD/mjesec** |

Procjena je precizna samo u odnosu na navedene ulazne pretpostavke. Stvarni racun ovisi o broju sati, stvarno zauzetom storageu, transakcijama i prometu. U zavrsnom dokumentu treba navesti i datum cijena i pretpostavke; sama brojka bez njih nije precizna procjena.

## Utjecaj Azure for Students kredita

Azure for Students daje 100 USD kredita koji vrijedi 12 mjeseci, ne 100 USD svaki mjesec. Sluzbeni opis ponude je na [Azure for Students](https://azure.microsoft.com/en-us/free/students). Potpuna okolina aktivna 730 sati potrosila bi kredit prije kraja mjeseca.

Za projekt je ispravno:

1. deployati cijelu okolinu;
2. izvrsiti testove i snimiti video/screenshotove;
3. dealocirati VM-ove ako se test nastavlja uskoro;
4. potpuno ukloniti Resource Grupe kada dokazi vise nisu potrebni.

Priblizni trosak osmosatnog aktivnog demonstracijskog prozora je oko **3,8 USD**, ovisno o prometu i storage transakcijama. Compute, Load Balancer, public IP i diskovi naplacuju se i za kratki period po odgovarajucoj obracunskoj jedinici. `Stopped (deallocated)` zaustavlja VM compute naplatu, ali diskovi, LB i public IP ostaju naplativi.

## Zasto nije odabran Azure Firewall ili NAT Gateway po developeru

- Azure Firewall bi bio sigurnosno i operativno kvalitetniji shared egress, ali njegov fiksni mjesecni trosak nije razuman za studentski laboratorij.
- NAT Gateway po developer VNetu zahtijevao bi dodatni public IP za svaki spoke i povecao fiksni trosak. To bi takoder oslabilo doslovni zahtjev da samo Jump Host ima javni IP.
- Jump/NVA pristup koristi postojeci obavezni VM i jedan public IP. Nedostatak je single point of failure, sto je prihvatljivo i dokumentirano za testing environment.

## Dokaz u Azure Pricing Calculatoru

Za predaju uz tablicu treba dodati screenshot Azure Pricing Calculatora s istim pretpostavkama. Unesite Linux, PAYG, 730 sati, dva B2s i jedan A1_v2 u France Central, dva B2s i jedan A1_v2 u Norway East, dva B1s u Switzerland North, cetrnaest E4 LRS diskova, dva Standard Load Balancera, jedan Standard public IPv4 te navedeni storage i global peering promet. Ako Calculator prikaze novu cijenu, tablicu treba osvjeziti i zabiljeziti novi datum.
