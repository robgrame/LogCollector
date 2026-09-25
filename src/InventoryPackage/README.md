# Custom Inventory - pacchetto Windows universale

Versione **1.9.0**, Windows PowerShell **5.1 a 64 bit**, contesto SYSTEM.
Il pacchetto richiede **LogCollector Core 1.11.0 o successivo** come dipendenza Intune.
Non richiede repository, OneDrive, PowerShell Gallery, Workspace ID/Primary Key o
Function key sul dispositivo. Codice e nomi dei task non dipendono da un cliente;
endpoint, cliente e criteri certificato provengono dalla configurazione protetta del Core.

## Configurazione e destinazioni

`Config.psd1` contiene soltanto i parametri specifici del collector:

| Parametro | Significato |
|---|---|
| DeviceTableName | Tabella hardware; default DeviceInventory_CL |
| AppTableName | Tabella software; default AppInventory_CL |
| CollectDeviceInventory / CollectAppInventory | Aree da raccogliere |
| MaxAttempts / TimeoutSeconds | Tentativi e timeout per singola richiesta |

`FrontendUrl`, `Environment`, `CustomerName`, `SubmissionEnabled`, selezione del
certificato e vincoli PKI vengono letti con `Get-LogCollectorEndpointConfiguration`.
Per cambiare questi valori si aggiorna esclusivamente il package Core; Inventory
adotta la nuova configurazione alla successiva esecuzione senza essere rigenerato.

I valori iniziali **DeviceInventory_CL** e **AppInventory_CL** conservano i nomi delle
tabelle esistenti. Non vengono rinominate o sostituite con InventoryWindows_CL.
Il collector conserva i campi hardware originari, NetworkAdapters/DiskHealth e i
campi applicativi, comprese le applicazioni dell'utente interattivo nel suo hive
HKU caricato; non monta gli hive degli utenti offline.

**Il nome della tabella da solo non garantisce la compatibilita delle query.**
Prima dell'invio riprodurre gli schemi effettivi, compresi suffissi tipizzati
(`_s`, `_b`, ecc.), tipi, campi annidati e trasformazioni DCR.
Il client conserva i nomi JSON originari; non inventa suffissi.
Il pacchetto non crea tabelle ne modifica Azure. Impostare `SubmissionEnabled` nel
Core solo dopo aver configurato tabelle, stream/DCR e mapping sia nell'intake sia nel worker.

## Contenuto

- `Run-Inventory.ps1`: raccolta e invio separato alle destinazioni configurate.
- `Sync-Spool.ps1`: ritrasmissione senza nuova raccolta.
- `Inventory.Collection.psm1` / `Inventory.Runtime.psm1`: raccolta e integrazione.
- dipendenza esterna: LogCollector Core installa `LogCollector.Client` 1.11.0 o successivo.
- `Inventory.Logging.psm1`: logger locale protetto, condiviso dalle entry point.
- `Install.ps1`, `Uninstall.ps1`, `Detect.ps1`: gestione Intune Win32.
- `Config.psd1`: sole opzioni specifiche del collector.

## Installazione / Intune

Pacchettizzare **l'intera cartella**, scegliendo `Install.ps1` come setup file.
Eseguire in contesto SYSTEM con host PowerShell a 64 bit. Per Intune Win32,
se il comando viene lanciato dall'agent a 32 bit:

```text
%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Install.ps1
```

Da un host gia a 64 bit usare System32 al posto di Sysnative.
Per disinstallare usare il percorso di installazione, non la cache IME: l'uninstall
command deve puntare a `Uninstall.ps1` nella cartella versionata copiata dall'installer
(vedi sotto), cosi' la disinstallazione di una versione resta legata allo script con cui
e' stata installata anche se il pacchetto Intune viene poi aggiornato.
Caricare `Detect.ps1` GENERATO insieme al pacchetto come regola di detection, con esecuzione a 32 bit su
client a 64 bit impostata a **No**.

La detection contiene lo SHA256 del Config.psd1 finale, richiede Core 1.11.0 e controlla
azione, principal SYSTEM e abilitazione dei task rispetto al Core. Per applicare una nuova configurazione
senza disinstallare, aggiornare nella stessa app Intune sia il contenuto .intunewin
sia il relativo Detect.ps1, con assegnazione Required. La configurazione precedente
non soddisfa la nuova detection: Intune riesegue l'installer. Non usare il template
Detect.ps1 della repository e non modificare Config.psd1 dopo la generazione.
Per una variante configurata, passare -ConfigurationPath al builder: viene rigenerata
anche la detection. Versione del codice e hash della configurazione sono distinti.

L'installer copia tutti i componenti in:

```text
C:\Program Files\<CustomerName>\CustomInventory
```

Il percorso non contiene la versione. Il file `Version` nella directory installata
contiene la versione del package (`1.9.0`) ed è verificato dalla detection.

Il percorso viene protetto per SYSTEM/amministratori; percorsi preesistenti non
attendibili o reparse point vengono rifiutati, non riparati automaticamente.
Rieseguire l'installer dalla cartella di distribuzione per aggiornare tutti i file,
anche se esistono gia; attendere la fine dei task del pacchetto eventualmente attivi.
Ogni dispositivo ha una configurazione di questo pacchetto, non piu installazioni
concorrenti per clienti diversi.

Sono registrati due task dedicati sotto `\LogCollector\`:

| Task | Frequenza |
|---|---|
| LogCollector-CustomInventory | Mercoledi/sabato 09:00, RandomDelay PT2H |
| LogCollector-CustomInventory-Spool | Ogni ora, senza rieseguire il collector |

Entrambi seguono il valore `SubmissionEnabled` configurato nel Core.
I task preesistenti di altri collector non vengono modificati.
Detection positiva significa installato, non ingestione attiva o completata.
La disinstallazione rimuove solo questi task e conserva file e spool, evitando
di cancellare dati eventualmente condivisi con altri sender.

## Log locali

Dalla versione 1.4.5 vengono scritti log JSON Lines (un oggetto JSON per riga) sotto:

```text
C:\ProgramData\<CustomerName>\CustomInventory\Logs\
    Install.log
    Inventory.log
    Spool.log
```

Se un percorso log creato da una release precedente non supera i controlli ACL correnti,
nessuna entry point lo ripara o vi scrive. Installazione, disinstallazione, raccolta e drain
usano invece il fallback protetto
`C:\ProgramData\LogCollectorInventory\<CustomerName>\CustomInventory-Fallback-1.9.0\Logs\`,
separato dall'albero ACL cliente primario; se anche il fallback non è
disponibile, il logging diagnostico viene disabilitato senza bloccare l'operazione principale.

Install.log include installazione e disinstallazione. Inventory.log include
raccolta, invio e anche esecuzioni Preview/QueueOnly; Spool.log riguarda il task
di ritrasmissione. Non e necessario un utente interattivo. La detection non scrive
log e non modifica il dispositivo. Install/Uninstall con -WhatIf non creano log.

Ogni esecuzione ha un RunId per correlare gli eventi, con timestamp UTC e PID.
Sono registrati versione, hash configurazione, endpoint, fasi/provider, conteggi,
selezione del certificato (thumbprint e scadenza), tentativi HTTP, codici, retry,
percorsi delle entry accodate e riepiloghi di consegna. I dati completi rimangono
nello spool, non nei log.

Gli errori includono fase, tipo eccezione, HResult e categoria, senza
Exception.Message, stack trace o contenuti delle risposte HTTP. I warning della
raccolta riportano funzione/fase e riga sorgente, non il messaggio potenzialmente
contenente dati inventariati. Console e codici di uscita mantengono il comportamento
precedente. Non sono salvati payload, firme, chiavi private o trascrizioni della console.

Limiti predefiniti: 2 MiB per file, quattro archivi oltre al file attivo per
componente, conservazione archivi di 14 giorni applicata alle scritture.
Il limite complessivo dei tre componenti e circa 30 MiB, oltre ai piccoli file
di lock. Nessun processo separato di pulizia; i log restano dopo la disinstallazione.
SYSTEM e amministratori sono gli unici soggetti ammessi. Directory/file non
attendibili o reparse point sono rifiutati, non riparati automaticamente.

Un errore di inizializzazione su entrambi i percorsi produce solo un warning metadata-only
e l'operazione continua senza diagnostic sink. Gli errori di scrittura successivi a
un'inizializzazione riuscita restano espliciti. Errori del parser,
vincoli #Requires o modulo logger mancante non possono essere salvati da un logger
che non e ancora disponibile. Restano visibili nell'esito/console del processo.

Per leggere gli ultimi eventi da una console elevata:

```powershell
Get-Content 'C:\ProgramData\<CustomerName>\CustomInventory\Logs\Install.log' -Tail 30
Get-Content 'C:\ProgramData\<CustomerName>\CustomInventory\Logs\Inventory.log' -Tail 50
Get-Content 'C:\ProgramData\<CustomerName>\CustomInventory\Logs\Spool.log' -Tail 50
```

## Prova locale e attivazione

Nel percorso installato, da Windows PowerShell a 64 bit elevato o SYSTEM:

```powershell
.\Run-Inventory.ps1 -Preview
.\Run-Inventory.ps1 -QueueOnly
```

Preview raccoglie e restituisce soltanto conteggi: nessun invio, spool o ricerca
certificato. QueueOnly accoda dati locali protetti senza HTTP.
Entrambi richiedono identita Entra valida e configurazione Core installata.
Non stampare payload, firme o credenziali nei log di distribuzione.

Dopo la preparazione delle destinazioni Azure distribuire un Core con
`SubmissionEnabled=true`. Aggiornare Inventory solo se cambiano tabelle, aree di
raccolta, retry o timeout; endpoint e criteri PKI non richiedono un nuovo package Inventory.
Per una prova immediata, senza attendere il trigger con ritardo casuale:

```powershell
Start-ScheduledTask -TaskPath '\LogCollector\' -TaskName 'LogCollector-CustomInventory'
```

Non eseguire contemporaneamente un collector equivalente sullo stesso dispositivo
durante il pilot, per evitare duplicati. Verificare i record in entrambe le tabelle
e le query esistenti prima del rollout. HTTP 202 indica presa in carico, non
consegna gia completata in Log Analytics. Gli errori di invio mantengono exit code
nonzero anche quando il dato e stato conservato nello spool.

## Limiti

Invii separati per tabella, fino a 500 record e circa 3 MiB per envelope; ogni record
deve rientrare in 750 KiB, lasciando margine per i metadati server. Nessun valore
viene troncato. Un record troppo grande interrompe il preflight prima di qualsiasi invio.

I retry usano backoff esponenziale e jitter. Lo spool condiviso per endpoint usa
la policy del modulo: 7 giorni, 500 entry, 64 MiB. Scadenza/quota possono eliminare
le entry meno recenti: non e una conservazione illimitata. Altri sender che usano
lo stesso endpoint e spool possono ritrasmettere le entry QueueOnly; questa opzione
non e una sospensione globale della coda.

Gli avvisi di raccolta indicano provider/dati opzionali indisponibili, non uno
stato hardware positivo. Non vengono raccolte password di ripristino BitLocker.
La raccolta e derivata dal contratto di inventario originale; nessuno script
cliente originale viene modificato durante la generazione o l'installazione.
