# Aggiungere autonomamente un nuovo tipo di raccolta

Questa procedura descrive come abilitare un nuovo tipo di dati nella piattaforma LogCollector usando esclusivamente il **Portale Azure** e le risorse già distribuite.

Non richiede modifiche al codice delle Azure Function, nuovi endpoint, nuove code, nuovi account di archiviazione o nuove Function App. La modalità di esportazione richiede però **LogCollector.Client 1.5.0 o successivo**, che espone `Export-LogCollectorSchema`; verificare la versione installata prima di iniziare.

## 1. Risultato atteso

Al termine della procedura:

1. nel workspace Log Analytics esiste una nuova tabella personalizzata;
2. il DCR già usato da LogCollector contiene lo stream e il data flow della nuova tabella;
3. Frontend e Worker autorizzano lo stesso mapping tabella/stream;
4. uno script client può inviare record al consueto endpoint `/api/submit`;
5. i dati sono interrogabili dalla nuova tabella in Log Analytics.

Il percorso rimane:

```text
Script client
  -> Function App Frontend /api/submit
  -> Blob Storage + Service Bus esistenti
  -> Function App Worker
  -> DCE e DCR esistenti
  -> nuova tabella Log Analytics
```

> **Condizione di gestione:** questa procedura modifica direttamente le risorse Azure dal Portale. Un successivo deployment infrastrutturale basato su una configurazione precedente può ripristinare DCR e impostazioni delle Function, eliminando il nuovo mapping. Prima di consegnare l'autonomia al cliente, il proprietario della piattaforma deve quindi assicurare che tali deployment siano bloccati oppure che le modifiche approvate dal cliente vengano riconciliate nella configurazione autorevole. Il cliente non deve modificare template infrastrutturali, ma la change request deve essere comunicata al relativo proprietario.

## 2. Quando usare questa procedura

Usare una nuova tabella quando i dati hanno:

- uno scopo operativo distinto;
- uno schema stabile e interrogabile;
- requisiti di conservazione o piano tabella specifici;
- query, dashboard o alert dedicati.

Non creare una nuova tabella per ogni singolo script se più script producono lo stesso tipo logico di evento. In quel caso usare la stessa tabella e distinguere i produttori tramite la colonna `Source`.

## 3. Prerequisiti e autorizzazioni

Prima di iniziare, identificare:

- subscription e resource group di LogCollector;
- workspace Log Analytics;
- Data Collection Rule (DCR) usata dal Worker;
- Data Collection Endpoint (DCE) associato;
- Function App Frontend;
- Function App Worker;
- URL Frontend, nel formato `https://<frontend>.azurewebsites.net/api/submit`;
- almeno un dispositivo autorizzato per il test.

Autorizzazioni Azure consigliate:

| Ambito | Ruolo minimo indicativo | Utilizzo |
|---|---|---|
| Workspace Log Analytics | Log Analytics Contributor | Creazione e gestione della tabella |
| DCR e relativo resource group | Monitoring Contributor | Modifica di stream e data flow |
| Entrambe le Function App | Website Contributor o ruolo equivalente | Modifica delle impostazioni applicative |
| Log Analytics | Log Analytics Reader | Verifica dei record |
| Application Insights e Service Bus | Reader | Diagnostica del flusso |

Applicare il principio del privilegio minimo e usare gli stessi processi approvativi adottati dal cliente per le modifiche in produzione.

Verificare sul computer usato per generare il campione che sia disponibile il comando introdotto in LogCollector.Client 1.5.0:

```powershell
Import-Module 'C:\Program Files\LogCollector\Modules\LogCollector.Client\1.5.0\LogCollector.Client.psd1' -ErrorAction Stop
Get-Command Export-LogCollectorSchema -ErrorAction Stop
(Get-Module LogCollector.Client).Version
```

Se il comando non è presente, aggiornare il modulo client prima di usare la modalità `-ExportSchema`. Non è invece necessario aggiornare la Function per questa funzionalità.

## 4. Informazioni da raccogliere prima della modifica

### 4.1 Individuare DCR e DCE usati dal Worker

1. Aprire il **Portale Azure**.
2. Aprire la Function App **Worker**.
3. Selezionare **Impostazioni > Variabili di ambiente**. In alcune versioni del portale la voce è denominata **Configurazione**.
4. Annotare senza modificarli:
   - `Ingestion__DataCollectionRuleId`;
   - `Ingestion__DataCollectionEndpoint`;
   - `Ingestion__StreamMap`.
5. Aprire **Azure Monitor > Regole di raccolta dati** e individuare il DCR il cui **ID immutabile** corrisponde a `Ingestion__DataCollectionRuleId`.
6. Aprire la **Vista JSON** del DCR e verificare che:
   - `kind` sia `Direct`;
   - `properties.dataCollectionEndpointId` punti a un DCE esistente;
   - `properties.destinations.logAnalytics[].workspaceResourceId` punti al workspace corretto.
7. Aprire il DCE e verificare che DCE, DCR e workspace siano nella stessa area geografica Azure.
8. Verificare di avere almeno accesso in lettura al DCE e il diritto di modificare il DCR. Se il DCR è in un altro resource group, controllare i ruoli anche su quel resource group.

Il wizard del Portale per i log personalizzati basati su DCR richiede un DCE e mostra soltanto DCR compatibili e accessibili all'utente. Non selezionare un DCR o DCE differente: il Worker invia i dati esclusivamente al DCR identificato dalle proprie impostazioni correnti.

Se il DCR corrispondente non esiste, non è visibile oppure non soddisfa queste verifiche, interrompere la procedura prima di creare la tabella. Creare una seconda DCR senza aggiornare e migrare il Worker produrrebbe una tabella che la pipeline LogCollector non utilizza.

### 4.2 Salvare la configurazione iniziale

Prima della modifica, copiare in una change request o in un sistema documentale protetto:

- valore completo di `Ingestion__StreamMap` del Frontend;
- valore completo di `Ingestion__StreamMap` del Worker;
- nome e ID immutabile del DCR;
- nome della nuova tabella;
- schema concordato;
- data, operatore e riferimento della modifica.

Le due mappe devono essere uguali. Se risultano già differenti, interrompere la procedura e correggere prima la configurazione esistente.

## 5. Progettare nome e schema

### 5.1 Nome della tabella

Usare un nome descrittivo, per esempio:

```text
SecureBootInventory_CL
RemediationResults_CL
DeviceHealth_CL
```

Regole:

- il nome deve iniziare con una lettera;
- usare solo lettere ASCII, numeri e underscore;
- per le colonne usare nomi da 2 a 45 caratteri;
- lunghezza massima del nome tabella: 100 caratteri;
- il nome completo della tabella personalizzata deve terminare con `_CL`;
- nel wizard del Portale Azure inserire normalmente il nome **senza** `_CL`, perché il portale aggiunge automaticamente il suffisso;
- non riutilizzare il nome di una tabella con significato o schema differente.

### 5.2 Colonne obbligatorie di piattaforma

Ogni tabella usata da LogCollector deve contenere queste colonne:

| Colonna | Tipo Log Analytics | Origine |
|---|---|---|
| `TimeGenerated` | `datetime` | Istante di elaborazione impostato dal Worker |
| `CollectedAtUtc` | `datetime` | Istante di raccolta dichiarato dal client |
| `EntraDeviceId` | `string` | Identità del dispositivo validata dal Frontend |
| `DeviceName` | `string` | Nome del dispositivo |
| `IntuneDeviceId` | `string` | Identificativo di enrollment, se disponibile |
| `CorrelationId` | `string` | Identificativo end-to-end della richiesta |
| `Source` | `string` | Nome logico dello script o del produttore |
| `RecordIndex` | `int` | Posizione del record nel batch, a partire da zero |

Queste colonne sono riservate. Lo script client non deve usarle per trasmettere valori applicativi: il Worker elimina eventuali valori omonimi e inserisce quelli validati dalla piattaforma.

### 5.3 Colonne specifiche

Aggiungere solo i campi necessari alle query. Tipi comunemente usati:

| Dato | Tipo consigliato |
|---|---|
| Testo, versione, stato | `string` |
| Conteggio intero | `int` o `long` |
| Misura decimale | `real` |
| Vero/falso | `boolean` |
| Data e ora UTC | `datetime` |
| Oggetto o array JSON | `dynamic` |

Indicazioni:

- mantenere stabile il tipo di ogni colonna;
- usare date UTC in formato ISO 8601;
- usare `dynamic` per oggetti o array realmente strutturati;
- non serializzare due volte il JSON;
- evitare nomi riservati da Azure Monitor;
- non inserire password, token, chiavi, certificati privati o altri segreti;
- applicare minimizzazione e classificazione dei dati personali prima della raccolta.

## 6. Preparare il JSON campione

Il wizard usa un JSON campione per derivare lo schema. Il file deve contenere un array con almeno una **riga finale**, cioè il formato che il Worker invierà al DCR, non l'intero envelope ricevuto da `/api/submit`.

Esempio per `SecureBootInventory_CL`:

```json
[
  {
    "TimeGenerated": "2026-09-07T09:00:00.0000000Z",
    "CollectedAtUtc": "2026-09-07T08:59:55.0000000Z",
    "EntraDeviceId": "00000000-0000-0000-0000-000000000000",
    "DeviceName": "DEVICE-EXAMPLE",
    "IntuneDeviceId": "11111111-1111-1111-1111-111111111111",
    "CorrelationId": "22222222-2222-2222-2222-222222222222",
    "Source": "SecureBootCollector",
    "RecordIndex": 0,
    "SecureBootEnabled": true,
    "FirmwareType": "UEFI",
    "Manufacturer": "Contoso",
    "Model": "Model 1",
    "CollectionRunId": "33333333-3333-3333-3333-333333333333",
    "Certificates": []
  }
]
```

Usare valori fittizi e non dati sensibili reali. Tutte le colonne desiderate devono comparire nel campione con valori che permettano al portale di riconoscere correttamente il tipo.

## 7. Esportare lo schema direttamente dal nuovo collector

Il cliente non deve scrivere o generare la DCR. Deve aggiungere al proprio script di raccolta una modalità `-ExportSchema` e usare il metodo pubblico `Export-LogCollectorSchema` del modulo LogCollector.

La funzione riceve gli stessi oggetti che lo script invierebbe con `Send-LogCollectorData` e produce un file JSON campione nel formato della **riga finale** inviata dal Worker ad Azure Monitor. Il Portale Azure usa questo file per rilevare nomi e tipi delle colonne durante la creazione della tabella/DCR.

La modalità di esportazione:

- esegue la normale raccolta locale;
- non cerca l'identità del dispositivo;
- non cerca certificati;
- non contatta la Function o Azure;
- non invia né accoda telemetria;
- non crea e non modifica la DCR.

### Struttura consigliata per ogni nuovo script

```powershell
[CmdletBinding()]
param(
    [switch] $ExportSchema,
    [string] $SchemaOutputPath = '.\SecureBootInventory-schema.json'
)

Import-Module 'C:\Program Files\LogCollector\Modules\LogCollector.Client\1.5.0\LogCollector.Client.psd1' `
    -ErrorAction Stop

# La funzione di raccolta è specifica del cliente.
$records = @(
    [pscustomobject]@{
        SecureBootEnabled = $true
        FirmwareType      = 'UEFI'
        Manufacturer      = 'Contoso'
        Model             = 'Model 1'
        Certificates      = @(
            [pscustomobject]@{
                Subject    = 'CN=Example'
                Thumbprint = '0000000000000000000000000000000000000000'
            }
        )
    }
)

if ($ExportSchema) {
    Export-LogCollectorSchema `
        -TableName 'SecureBootInventory_CL' `
        -Source 'SecureBootCollector' `
        -Records $records `
        -OutputPath $SchemaOutputPath `
        -Force
    return
}

Send-LogCollectorData `
    -FrontendUrl 'https://<frontend>.azurewebsites.net/api/submit' `
    -TableName 'SecureBootInventory_CL' `
    -Source 'SecureBootCollector' `
    -Records $records
```

Per generare il campione:

```powershell
.\SecureBootInventory.ps1 `
    -ExportSchema `
    -SchemaOutputPath 'C:\Temp\SecureBootInventory-schema.json'
```

Il file risultante è un array JSON e include automaticamente le colonne protette aggiunte dal Worker:

- `TimeGenerated`;
- `CollectedAtUtc`;
- `EntraDeviceId`;
- `DeviceName`;
- `IntuneDeviceId`;
- `CorrelationId`;
- `Source`;
- `RecordIndex`.

Il cliente non deve aggiungere manualmente queste colonne al proprio `$record`.

### Requisiti del campione

- raccogliere almeno un record rappresentativo;
- valorizzare tutte le proprietà che dovranno diventare colonne;
- evitare valori `$null`, perché il portale potrebbe non dedurne correttamente il tipo;
- mantenere lo stesso tipo per una proprietà in tutti i record;
- non usare nomi di colonne che differiscono solo per maiuscole/minuscole: export e invio li rifiutano;
- usare oggetti e array reali per le colonne che dovranno essere `dynamic`;
- esportare il file solo su un disco locale fisso; percorsi UNC, device path, unità di rete e supporti rimovibili sono rifiutati;
- controllare e, se necessario, anonimizzare il file prima di consegnarlo a chi configura Azure;
- non includere password, token, chiavi o altri segreti.

Per raccolte con record di forme diverse, `Export-LogCollectorSchema` esporta fino a 10 record per impostazione predefinita. Il limite può essere regolato con `-MaxRecords`, fino a 100. Tutte le forme devono comunque essere compatibili con un unico schema tabellare.

## 8. Creare la tabella e aggiornare il DCR dal Portale Azure

1. Nel Portale Azure aprire **Log Analytics workspaces**.
2. Selezionare il workspace usato da LogCollector.
3. Aprire **Tabelle**.
4. Selezionare **Crea > Nuovo log personalizzato (basato su DCR)**.
5. Inserire il nome della tabella senza `_CL`.
6. Scegliere il piano della tabella previsto dal cliente. Se non esiste una decisione specifica, mantenere **Analytics**.
7. Se il Portale propone il **DCR esistente già usato dal Worker**, selezionarlo e scegliere anche il DCE associato.

   Una DCR che contiene già uno o più stream di log personalizzati può non essere proposta dal wizard. Il wizard non è quindi un metodo affidabile per estendere una DCR multi-stream come quella di LogCollector.

8. Se l'elenco dei DCR è vuoto, annullare il wizard e verificare, nell'ordine:
   1. tenant e sottoscrizione selezionati nel Portale;
   2. presenza del DCR ottenuto dall'ID immutabile configurato sul Worker;
   3. permessi dell'operatore sul resource group del DCR e del DCE;
   4. DCR di tipo `Direct`, associato al DCE;
   5. DCE, DCR e workspace nella stessa regione;
   6. destinazione Log Analytics del DCR riferita al workspace selezionato.

   **Crea una nuova regola di raccolta dati** crea una seconda risorsa autonoma, non una regola interna al DCR esistente. Il nuovo DCR avrebbe un ID immutabile diverso e non sarebbe usato dal Worker.

   Per LogCollector, se la DCR esistente non compare, la procedura corretta è:
   1. creare la tabella con lo schema richiesto;
   2. esportare la definizione JSON completa del DCR esistente;
   3. aggiungere alla stessa definizione il nuovo `streamDeclarations` e il relativo `dataFlows`, senza eliminare quelli presenti;
   4. ridistribuire **la stessa risorsa DCR**, mantenendone nome, resource ID, immutable ID, DCE e destinazione;
   5. aggiornare poi `Ingestion__StreamMap` su Frontend e Worker.

   Questa modifica può essere eseguita interamente dal Portale tramite **DCR > Esporta modello > Distribuisci > Modifica modello**, oppure tramite Azure Resource Manager/CLI. Il JSON campione prodotto dallo script descrive lo schema dei dati, ma non sostituisce la definizione JSON del DCR.
9. Caricare il JSON campione soltanto se il wizard ha consentito di selezionare il DCR corretto.
10. Controllare lo schema rilevato:
    - presenza di tutte le colonne di piattaforma;
    - nomi esatti, incluse maiuscole e minuscole;
    - tipi coerenti;
    - presenza delle colonne specifiche.
11. Aprire l'editor della trasformazione.
12. Se il formato in ingresso coincide con lo schema della tabella, usare una trasformazione pass-through:

```kusto
source
```

13. Eseguire l'anteprima della trasformazione e verificare che l'output contenga tutte e sole le colonne attese.
14. Applicare la trasformazione.
15. Riesaminare il riepilogo e creare la tabella.

### Verifiche sul DCR

Dopo la creazione:

1. aprire **Azure Monitor > Regole di raccolta dati**;
2. aprire il DCR esistente;
3. verificare che sia presente uno stream denominato:

```text
Custom-<NomeTabellaCompleto>
```

Esempio:

```text
Custom-SecureBootInventory_CL
```

4. verificare che lo stream dichiari tutte le colonne con i tipi corretti;
5. verificare che il data flow indirizzi lo stream alla nuova tabella del workspace;
6. confermare che ID immutabile e DCE siano rimasti quelli configurati nel Worker.

La sola creazione della tabella non è sufficiente: stream declaration e data flow devono esistere nel DCR effettivamente usato dal Worker.

## 9. Autorizzare il nuovo tipo nel Frontend e nel Worker

`Ingestion__StreamMap` è una allow-list. Un nome non presente viene rifiutato anche se tabella e DCR esistono.

Formato di ogni voce:

```text
NomeTabella_CL=Custom-NomeTabella_CL
```

Più voci sono separate da punto e virgola. Esempio:

```text
InventoryWindows_CL=Custom-InventoryWindows_CL;SecureBootInventory_CL=Custom-SecureBootInventory_CL
```

### Ordine consigliato

Configurare prima il **Worker** e poi il **Frontend**. In questo modo il Frontend non accetta il nuovo tipo finché il Worker non è pronto a elaborarlo.

### 9.1 Aggiornare il Worker

1. Aprire la Function App Worker.
2. Selezionare **Impostazioni > Variabili di ambiente** o **Configurazione**.
3. Aprire `Ingestion__StreamMap`.
4. Conservare integralmente tutte le voci esistenti.
5. Aggiungere `;` e il nuovo mapping.
6. Controllare che non vi siano duplicati, errori di battitura o spazi nel nome tabella.
7. Salvare.
8. Attendere il completamento del riavvio automatico causato dalla modifica.

Non modificare:

- `Ingestion__DataCollectionRuleId`;
- `Ingestion__DataCollectionEndpoint`;
- impostazioni Service Bus;
- impostazioni Storage;
- identità gestite o assegnazioni di ruolo.

### 9.2 Aggiornare il Frontend

Ripetere gli stessi passaggi sulla Function App Frontend, impostando **lo stesso valore completo** di `Ingestion__StreamMap`.

Dopo il salvataggio, confrontare nuovamente i valori delle due app: devono coincidere carattere per carattere.

### 9.3 Verificare lo stato del Frontend

Da un dispositivo autorizzato, interrogare l'endpoint di salute usando il certificato client previsto dalla soluzione:

```powershell
$certificate = Get-Item 'Cert:\LocalMachine\My\<thumbprint>'
Invoke-RestMethod `
    -Uri 'https://<frontend>.azurewebsites.net/api/health' `
    -Certificate $certificate
```

La proprietà `configuredIngestionTargets` deve essere maggiore di zero e deve aumentare di uno rispetto al valore precedente. Questo controllo conferma la lettura della mappa, non l'ingestione end-to-end.

## 10. Instrumentare lo script client

Lo script deve inviare oggetti PowerShell, non una stringa JSON già serializzata.

Esempio:

```powershell
Import-Module 'C:\Program Files\LogCollector\Modules\LogCollector.Client\<versione>\LogCollector.Client.psd1' -ErrorAction Stop

$endpoint = 'https://<frontend>.azurewebsites.net/api/submit'

$record = [pscustomobject]@{
    SecureBootEnabled = $true
    FirmwareType      = 'UEFI'
    Manufacturer      = 'Contoso'
    Model             = 'Model 1'
    CollectionRunId   = [guid]::NewGuid().Guid
    Certificates      = @()
}

$result = Send-LogCollectorData `
    -FrontendUrl $endpoint `
    -TableName 'SecureBootInventory_CL' `
    -Source 'SecureBootCollector' `
    -Records @($record)

$result | Select-Object Disposition, StatusCode, Attempts, Spooled, SpoolDirectory
```

Regole:

- usare sempre `/api/submit` per le nuove raccolte;
- `TableName` deve coincidere esattamente con il lato sinistro del mapping;
- `Source` identifica il produttore, ma non autorizza né instrada i dati;
- ogni elemento di `Records` diventa una riga;
- i nomi e i tipi dei campi devono corrispondere al DCR;
- conservare il logging locale dello script;
- non distribuire Workspace ID, primary key, Function key o credenziali Azure;
- non chiamare direttamente la Logs Ingestion API dal dispositivo.

## 11. Collaudo end-to-end

### 11.1 Inviare un record univoco

Aggiungere al record un identificativo applicativo facilmente ricercabile, per esempio `CollectionRunId = [guid]::NewGuid().Guid`. La colonna deve essere prevista nello schema della tabella.

Il client corrente non espone il `CorrelationId` della risposta nell'oggetto risultato.

L'esito `Delivered` con HTTP `202` significa che il Frontend ha accettato la richiesta per l'elaborazione asincrona. Non garantisce ancora che la riga sia stata scritta in Log Analytics.

### 11.2 Verificare in Log Analytics

Attendere il normale ritardo di ingestione, quindi eseguire:

```kusto
SecureBootInventory_CL
| where TimeGenerated > ago(30m)
| where Source == "SecureBootCollector"
| project TimeGenerated, CollectedAtUtc, DeviceName, EntraDeviceId,
          CorrelationId, RecordIndex, SecureBootEnabled, FirmwareType
| order by TimeGenerated desc
```

Per cercare il collaudo specifico:

```kusto
SecureBootInventory_CL
| where CollectionRunId == "<collection-run-id>"
| order by RecordIndex asc
```

Dalla riga così individuata si può poi recuperare il `CorrelationId` generato dal Frontend per correlare i log dei componenti Azure.

Verificare:

- numero di righe uguale al numero di record inviati;
- `RecordIndex` progressivo;
- identificativo Entra e nome dispositivo corretti;
- tipi delle colonne corretti;
- assenza di dati sensibili non previsti;
- timestamp coerenti.

### 11.3 Verificare i componenti Azure

Se i dati non arrivano:

1. controllare i log del Frontend in Application Insights;
2. cercare il `CorrelationId`;
3. controllare i log del Worker;
4. controllare in Service Bus i conteggi **Active messages** e **Dead-letter messages**;
5. controllare nel DCR schema, stream e data flow;
6. verificare il ruolo **Monitoring Metrics Publisher** dell'identità gestita Worker sul DCR esistente;
7. verificare che il payload Blob associato sia ancora disponibile per la diagnosi.

Non modificare o eliminare messaggi, blob o righe dead-letter prima di aver registrato la causa e il `CorrelationId`.

## 12. Errori frequenti

| Sintomo | Causa probabile | Azione |
|---|---|---|
| HTTP 400, tabella non accettata | Mapping assente o errato nel Frontend | Correggere `Ingestion__StreamMap` del Frontend |
| Richiesta accettata ma messaggio dead-letter | Mapping Worker assente, stream inesistente o schema incompatibile | Verificare Worker, DCR e tipi delle colonne |
| `configuredIngestionTargets` è 0 | Mappa mancante o completamente malformata | Ripristinare una mappa valida |
| Tabella esistente ma nessun dato | Tabella creata senza stream/data flow nel DCR usato dal Worker | Completare il DCR esistente |
| Dati in una tabella diversa | Mapping verso stream errato | Correggere entrambi i mapping dopo aver fermato il produttore |
| Valore di una colonna non accettato | Tipo JSON incompatibile con il tipo DCR | Correggere lo script o la definizione della colonna |
| Colonna applicativa mancante | Non inclusa nello schema o scartata dalla trasformazione | Aggiornare schema e trasformazione |
| Timestamp inatteso | Uso di data locale o formato ambiguo | Inviare UTC ISO 8601 |
| Campi complessi illeggibili | Oggetto serializzato come stringa anziché `dynamic` | Inviare oggetto/array e usare `dynamic` |
| Frontend e Worker si riavviano | Comportamento normale dopo il salvataggio delle impostazioni | Attendere il completamento prima del test |

## 13. Modifica di uno schema esistente

Una modifica allo schema richiede coordinamento tra script, tabella e DCR.

### Aggiunta di una colonna opzionale

1. aggiungere la colonna alla tabella;
2. aggiungerla alla stream declaration del DCR;
3. aggiornare la trasformazione se necessario;
4. testare il DCR;
5. distribuire lo script che valorizza la nuova colonna.

### Cambio di tipo o significato

Non cambiare direttamente il tipo o il significato di una colonna già popolata. È preferibile:

- aggiungere una nuova colonna con nome esplicito; oppure
- creare una tabella versione 2, per esempio `SecureBootInventoryV2_CL`, e migrare gradualmente produttori e query.

Questo evita errori di ingestione e interpretazioni incoerenti dei dati storici.

## 14. Rollback sicuro

Se la nuova raccolta deve essere disabilitata:

1. fermare o riconfigurare lo script produttore;
2. rimuovere il mapping **solo dal Frontend**, così da bloccare nuove richieste;
3. verificare che la coda non contenga più messaggi destinati alla nuova tabella;
4. gestire eventuali messaggi dead-letter e payload Blob;
5. rimuovere il mapping dal Worker;
6. conservare tabella, stream e data flow per il periodo necessario alle verifiche e alla conservazione dei dati;
7. eliminare le risorse logiche solo dopo approvazione esplicita e dopo aver valutato perdita dei dati, query, alert e dashboard dipendenti.

Non rimuovere prima lo stream dal DCR o il mapping Worker: payload già accettati diventerebbero non elaborabili.

Per un rollback della configurazione, ripristinare i valori completi di `Ingestion__StreamMap` salvati prima della modifica.

## 15. Checklist operativa

### Preparazione

- [ ] Concordato con il proprietario della piattaforma come preservare la modifica nei deployment infrastrutturali futuri
- [ ] Identificati workspace, DCR, DCE, Frontend e Worker corretti
- [ ] Verificato l'ID immutabile DCR configurato nel Worker
- [ ] Salvate entrambe le mappe correnti
- [ ] Concordati nome, scopo, proprietario e conservazione della tabella
- [ ] Approvati schema, classificazione dati e tipi
- [ ] Preparato JSON campione con dati fittizi

### Configurazione

- [ ] Creata la tabella nel workspace corretto
- [ ] Riutilizzati DCR e DCE esistenti
- [ ] Verificata la stream declaration `Custom-<Tabella_CL>`
- [ ] Verificato il data flow verso la nuova tabella
- [ ] Aggiunto il mapping al Worker senza rimuovere quelli esistenti
- [ ] Atteso il riavvio Worker
- [ ] Aggiunto lo stesso mapping al Frontend
- [ ] Atteso il riavvio Frontend
- [ ] Confrontate le mappe finali delle due app

### Collaudo

- [ ] Health endpoint raggiungibile con certificato client
- [ ] `configuredIngestionTargets` incrementato
- [ ] Record di prova accettato con HTTP 202
- [ ] Riga trovata in Log Analytics
- [ ] Verificati identità, timestamp, tipi e numero di righe
- [ ] Verificata assenza di messaggi dead-letter
- [ ] Registrati risultato, `CorrelationId` e operatore

## 16. Informazioni da conservare nel catalogo delle raccolte

Per ogni tipo mantenere una scheda con:

- nome tabella completo;
- descrizione e finalità;
- proprietario applicativo;
- script e versione produttrice;
- valore `Source` autorizzato per convenzione;
- schema con descrizione e tipo delle colonne;
- DCR, DCE e workspace;
- mapping tabella/stream;
- piano e conservazione della tabella;
- query di verifica;
- dashboard e alert dipendenti;
- classificazione dei dati;
- data di attivazione e ultima modifica;
- procedura di rollback.

## 17. Cosa non deve fare il cliente

Per aggiungere un normale tipo di raccolta non è necessario:

- creare o modificare il codice delle Azure Function;
- creare una nuova Function App;
- creare un nuovo endpoint HTTP;
- creare una nuova coda Service Bus;
- creare un nuovo container Blob;
- creare un nuovo account Storage;
- creare un nuovo DCR o DCE;
- distribuire Workspace ID o primary key;
- inserire segreti negli script;
- modificare certificati o autenticazione mTLS;
- modificare le identità gestite se si riutilizza il DCR esistente.

Una modifica applicativa è necessaria solo quando serve una nuova logica di business nel backend, per esempio validazioni specifiche, arricchimenti esterni, routing condizionale o un sistema di destinazione diverso da quello già supportato.

## 18. Riferimenti Microsoft

- [Tutorial: inviare dati ad Azure Monitor Logs tramite Logs Ingestion API dal Portale Azure](https://learn.microsoft.com/azure/azure-monitor/logs/tutorial-logs-ingestion-portal)
- [Creare e gestire tabelle personalizzate in Azure Monitor Logs](https://learn.microsoft.com/azure/azure-monitor/logs/create-custom-table)
- [Panoramica della Logs Ingestion API](https://learn.microsoft.com/azure/azure-monitor/logs/logs-ingestion-api-overview)
- [Creare Data Collection Rules dal Portale Azure](https://learn.microsoft.com/azure/azure-monitor/data-collection/data-collection-rule-create-portal)
- [Trasformazioni nei Data Collection Rules](https://learn.microsoft.com/azure/azure-monitor/data-collection/data-collection-transformations)
