# Custom Inventory - pacchetto Windows universale

Versione **1.0.0**, Windows PowerShell **5.1 a 64 bit**, contesto SYSTEM.
La cartella generata e autosufficiente: non richiede la repository, OneDrive,
PowerShell Gallery, Workspace ID/Primary Key o Function key sul dispositivo.
Codice, nomi dei task e percorsi di installazione non dipendono da un cliente.

## Configurazione e destinazioni

`Config.psd1` contiene i parametri del singolo deployment:

| Parametro | Significato |
|---|---|
| FrontendUrl | Endpoint HTTPS /api/inventory del deployment destinatario |
| Environment | Etichetta diagnostica facoltativa, non una prova di autenticazione |
| DeviceTableName | Tabella hardware; default DeviceInventory_CL |
| AppTableName | Tabella software; default AppInventory_CL |
| SubmissionEnabled | Invio abilitato; default false |
| CollectDeviceInventory / CollectAppInventory | Aree da raccogliere |
| CertificateThumbprint / CertificateIssuerLike | Selezione facoltativa del certificato |
| MaxAttempts / TimeoutSeconds | Tentativi e timeout per singola richiesta |

Per riusare il pacchetto in un altro tenant si cambia la configurazione, non il codice.
Il server deve fidarsi dei certificati previsti e, nel percorso Intune, autorizza
soltanto device Entra abilitati nel proprio tenant. Cambiare Environment non cambia
tenant o autorizzazioni. Non inserire credenziali o chiavi private nella configurazione.

I valori iniziali **DeviceInventory_CL** e **AppInventory_CL** conservano i nomi delle
tabelle esistenti. Non vengono rinominate o sostituite con InventoryWindows_CL.
Il collector conserva i campi hardware originari, NetworkAdapters/DiskHealth e i
campi applicativi, comprese le applicazioni dell'utente interattivo nel suo hive
HKU caricato; non monta gli hive degli utenti offline.

**Il nome della tabella da solo non garantisce la compatibilita delle query.**
Prima dell'invio riprodurre gli schemi effettivi, compresi suffissi tipizzati
(`_s`, `_b`, ecc.), tipi, campi annidati e trasformazioni DCR.
Il client conserva i nomi JSON originari; non inventa suffissi.
Il pacchetto non crea tabelle ne modifica Azure. Abilitare SubmissionEnabled
solo dopo aver configurato tabelle, stream/DCR e mapping sia nell'intake sia nel worker.

## Contenuto

- `Run-Inventory.ps1`: raccolta e invio separato alle destinazioni configurate.
- `Sync-Spool.ps1`: ritrasmissione senza nuova raccolta.
- `Inventory.Collection.psm1` / `Inventory.Runtime.psm1`: raccolta e integrazione.
- `Modules`: tutti i sei file di LogCollector.Client 1.0.0.
- `Install.ps1`, `Uninstall.ps1`, `Detect.ps1`: gestione Intune Win32.
- `Config.psd1`: configurazione del deployment.

## Installazione / Intune

Pacchettizzare **l'intera cartella**, scegliendo `Install.ps1` come setup file.
Eseguire in contesto SYSTEM con host PowerShell a 64 bit. Per Intune Win32,
se il comando viene lanciato dall'agent a 32 bit:

```text
%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Install.ps1
```

Da un host gia a 64 bit usare System32 al posto di Sysnative.
Per disinstallare usare il comando equivalente con `-File .\Uninstall.ps1`.
Caricare `Detect.ps1` come regola di detection, con esecuzione a 32 bit su
client a 64 bit impostata a **No**.

L'installer copia tutti i componenti in:

```text
C:\Program Files\LogCollector\CustomInventory\1.0.0
```

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

Entrambi sono **disabilitati** quando SubmissionEnabled=false.
I task preesistenti di altri collector non vengono modificati.
Detection positiva significa installato, non ingestione attiva o completata.
La disinstallazione rimuove solo questi task e conserva file e spool, evitando
di cancellare dati eventualmente condivisi con altri sender.

## Prova locale e attivazione

Nel percorso installato, da Windows PowerShell a 64 bit elevato o SYSTEM:

```powershell
.\Run-Inventory.ps1 -Preview
.\Run-Inventory.ps1 -QueueOnly
```

Preview raccoglie e restituisce soltanto conteggi: nessun invio, spool o ricerca
certificato. QueueOnly accoda dati locali protetti senza HTTP.
Entrambi richiedono identita Entra valida e configurazione endpoint esplicita.
Non stampare payload, firme o credenziali nei log di distribuzione.

Dopo la preparazione delle destinazioni Azure impostare SubmissionEnabled=true
nel Config.psd1 della distribuzione e rieseguire Install.ps1.
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
