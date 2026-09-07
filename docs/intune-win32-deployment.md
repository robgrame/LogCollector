# Custom Inventory 1.5.0 - distribuzione Intune Win32

Il pacchetto installa il collector hardware/software e tutti i moduli comuni.
Non servono Workspace ID, Primary Key, Function key o moduli da PowerShell Gallery.
Gli script originali cliente non vengono letti o modificati. Il modulo condiviso
è alla versione 1.5.0, supporta `/api/submit` e l'esportazione offline del campione schema.
Il pacchetto inventory passa a **1.5.0** per l'aggiornamento della dipendenza;
mantiene compatibili endpoint e tabelle precedenti. Il logging introdotto in 1.4.5
resta invariato (versioning Major.Minor.Build).

## 1. Preparazione del computer di packaging

Usare Windows con Windows PowerShell 5.1 o PowerShell 7 e .NET Framework 4.7.2
o successivo per il tool Microsoft. Non sono necessari privilegi amministrativi.
Scaricare `IntuneWinAppUtil.exe` dal repository ufficiale
[Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool),
consultando licenza e requisiti. La release usata per questo pacchetto e **1.8.7**.
Il wrapper richiede un eseguibile locale: non scarica/esegue aggiornamenti automatici
e non aggiunge il tool al payload dei dispositivi.

Dalla root della repository:

```powershell
.\scripts\Publish-IntuneWin32Package.ps1 `
    -IntuneWinAppUtilPath 'C:\Tools\IntuneWinAppUtil.exe' `
    -FrontendUrl 'https://<your-intake>.azurewebsites.net/api/inventory' `
    -Environment 'MSLabs'
```

La generazione NON installa task sul computer di packaging, NON crea log operativi, NON raccoglie
inventario, NON invia dati e NON carica l'app in Intune.

Output predefiniti:

| File/cartella | Utilizzo |
|---|---|
| `out\IntuneWin32\1.5.0\Output\Install.intunewin` | File da caricare nell'app Win32 |
| `out\IntuneWin32\1.5.0\Detect.ps1` | Script da caricare nella detection rule |
| `out\IntuneWin32\1.5.0\Intune-Deployment.md` | Copia di questa guida |
| `out\IntuneWin32\1.5.0\Source\1.5.0` | Tutti i 16 file inclusi nel payload, configurazione e logger compresi |

Il comando restituisce SHA256 del pacchetto, ConfigurationSha256 e stato SubmissionEnabled. Source e Output
sono separati: il tool non ingloba il proprio eseguibile o il file .intunewin.
Output gia esistenti sono rifiutati, anche dopo un tentativo fallito. Per un'altra
build usare un nuovo `-OutputRoot`, ad esempio `out\IntuneWin32-Pilot02`.
Conservare gli artefatti in una cartella amministrativa protetta: .intunewin
non e un contenitore adatto a custodire segreti.

## 2. Configurazione del pilot

Il comando precedente produce **SubmissionEnabled=false**. L'installazione crea
entrambi i task disabilitati: consente di provare installazione, detection e
raccolta locale, ma non l'ingestione end-to-end.

Nel laboratorio MSLabs, le destinazioni di questo collector sono
**DeviceInventory_CL** e **AppInventory_CL**. Non sostituirle con
InventoryWindows_CL: schemi, stream/DCR e allow-list/mapping di Intake e worker
devono essere predisposti prima dell'invio. Questo script non modifica Azure.

Per personalizzare endpoint, selezione certificato, CA, tabelle o attivazione:

```powershell
.\scripts\Publish-InventoryPackage.ps1 `
    -FrontendUrl 'https://<your-intake>.azurewebsites.net/api/inventory' `
    -Environment 'MSLabs' -OutputRoot '.\out\Inventory-PilotConfig'

# Modificare out\Inventory-PilotConfig\1.5.0\Config.psd1 con un editor.
# Impostare SubmissionEnabled = $true SOLO dopo la preparazione lato Azure.

.\scripts\Publish-IntuneWin32Package.ps1 `
    -IntuneWinAppUtilPath 'C:\Tools\IntuneWinAppUtil.exe' `
    -ConfigurationPath '.\out\Inventory-PilotConfig\1.5.0\Config.psd1' `
    -OutputRoot '.\out\IntuneWin32-Pilot02'
```

ConfigurationPath importa solo dati PSD1, non gli script di quella cartella:
il payload viene sempre costruito dai sorgenti correnti della repository.
La versione della configurazione deve coincidere con 1.5.0. La configurazione
viene validata dallo stesso runtime dell'installer prima di chiamare il tool.
Non inserire chiavi private o credenziali. I certificati non vengono esportati.
Per PKI vedere `docs\pki-ca-policy.md`: filtri Root/SubCA e trust server sono distinti.

**Modificare Source dopo la generazione non cambia il .intunewin gia prodotto.**
Ricreare il pacchetto e aggiornare il contenuto dell'app in Intune. Cambiare
soltanto Config.psd1 sul client non riabilita task disabilitati: rieseguire
l'installer dalla distribuzione aggiornata, non dalla cartella installata.
La detection generata incorpora lo SHA256 dei byte del Config.psd1 finale:
una modifica alla configurazione rende negativa la detection del NUOVO pacchetto
sui dispositivi che hanno ancora quella precedente, anche a parita di versione.
Non e necessario incrementare la versione degli script per una variante di configurazione:
la versione identifica il codice, ConfigurationSha256 identifica la configurazione.
Anche commenti, encoding e spazi modificano l'hash; non modificare manualmente
Config.psd1 dopo la generazione o sul dispositivo gestito.

### Aggiornamento della configurazione senza disinstallazione

1. Modificare una copia di Config.psd1 e generare un nuovo output con ConfigurationPath.
2. Nella STESSA app Win32, aggiornare il contenuto con il nuovo Install.intunewin e
   attendere il completamento dell'upload/elaborazione.
3. Sostituire anche la custom detection rule con il Detect.ps1 dello STESSO output.
   Non usare quello della repository: e un template senza hash.
4. Mantenere l'assegnazione **Required** al gruppo pilot e avviare una sincronizzazione
   del dispositivo, oppure attendere il normale ciclo di rivalutazione IME.

Nel passaggio da una versione precedente a 1.5.0 aggiornare anche la command line di uninstall al
percorso 1.5.0 indicato sotto. Per successive varianti di sola configurazione della
stessa versione le command line restano invariate.

La vecchia configurazione non soddisfa la nuova detection; Intune esegue di nuovo
Install.ps1, che aggiorna i file nello stesso percorso e registra i due task con
lo stato desiderato. La detection torna positiva quando configurazione e task
corrispondono. Non serve una disinstallazione preventiva e lo spool resta invariato.
Questo vale anche per true -> false, endpoint, filtri CA e altri parametri.
Se un task e in esecuzione l'installer segnala errore: attendere la fine e il retry,
senza interrompere una raccolta in corso.

Caricare SOLO il .intunewin lasciando la vecchia detection non attiva questo
meccanismo. Caricare SOLO Detect.ps1 puo invece provocare tentativi di reinstallare
il vecchio contenuto: mantenere la coppia allineata. Non assegnare contemporaneamente
due app con configurazioni diverse che gestiscono gli stessi task.
Con assegnazione solo Available non presumere enforcement automatico: usare Required
per applicare centralmente questi aggiornamenti.
La reinstallazione non e necessariamente immediata: Microsoft indica che un'app
Required non rilevata viene riproposta entro circa 24 ore. Una sincronizzazione
non garantisce di anticipare tutti i cicli IME. Riferimento:
[Intune Win32 - Detection rules](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-win32#step-4-detection-rules).

## 3. Creazione dell'app

Intune admin center > Apps > Windows > Add > **Windows app (Win32)**.
Caricare `Output\Install.intunewin`; nome suggerito: **LogCollector Custom Inventory 1.5.0**.

| Impostazione Program | Valore |
|---|---|
| Install behavior | System |
| Device restart behavior | No specific action |
| Installation time required | 15 minuti |
| Allow available uninstall | Yes, se il pilot usa Company Portal |
| Return codes | 0 = Success; 1 = Failed. Nessun riavvio richiesto dallo script |

**Install command** (una sola riga):

```text
"%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ".\Install.ps1"
```

**Uninstall command** (una sola riga, usa la copia installata, non la cache IME):

```text
"%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ProgramW6432%\LogCollector\CustomInventory\1.5.0\Uninstall.ps1"
```

Sysnative evita la redirezione a PowerShell 32 bit da Intune Management Extension.
Per prove manuali da una console gia a 64 bit usare System32 al posto di Sysnative
ed espandere le variabili con sintassi PowerShell, non `%...%`.
Gli script richiedono PowerShell FullLanguage; ExecutionPolicy Bypass non aggira
WDAC/AppLocker o policy di firma imposte dall'organizzazione.

## 4. Detection method

Rules format: **Use a custom detection script**.
Caricare **Detect.ps1 della stessa release**, disponibile accanto alla guida.

| Impostazione | Valore |
|---|---|
| Run script as 32-bit process on 64-bit clients | No |
| Enforce script signature check | No per i sorgenti non firmati del laboratorio |
| Esecuzione | Contesto System, coerente con Install behavior |

Lo script controlla l'hash atteso di Config.psd1, PackageVersion, presenza dei file
necessari e dei due task sotto `\LogCollector\`. Per ciascun task controlla
abilitazione coerente con SubmissionEnabled, principal SYSTEM con privilegi elevati
e l'unica azione PowerShell a 64 bit verso lo script della versione attesa.
Restituisce **exit 0 e stdout non vuoto** se
installato; exit 1 se non rilevato. Non usare la sola esistenza della cartella:
la disinstallazione conserva file e spool ma rimuove i task.
La detection puo essere positiva con task disabilitati SOLO se la configurazione
attesa ha SubmissionEnabled=false; non certifica l'ingestione. L'hash e un controllo
di corrispondenza per il deployment, non una firma o un nuovo sistema di autenticazione.
Per produzione, se si impone la firma, firmare gli script con il proprio processo
di code signing dopo la generazione dei file finali e prima del wrapping .intunewin,
e distribuire la relativa fiducia. Detect.ps1 va firmato dopo l'inserimento dell'hash,
non nella sua forma di template. Il wrapper di laboratorio non implementa una pipeline
di firma: non abilitare la verifica firma Intune sui suoi output non firmati.

## 5. Requirements

| Requisito | Impostazione/nota |
|---|---|
| Architecture | x64; non distribuire questo pilot a x86 o ARM64 |
| Minimum operating system | Windows 11 24H2 per il pilot; usare una versione supportata nel tenant |
| Gestione | Device enrollato in Intune, idoneo alle app Win32, IME disponibile |
| Edizione | Windows Pro sufficiente; non dipende dalle licenze Remediations |
| PowerShell client | Windows PowerShell 5.1 a 64 bit, FullLanguage, moduli Windows integrati CIM/ScheduledTasks |
| Identita per la raccolta | Entra device ID valido, dispositivo Entra joined o hybrid joined |
| Certificato per invio | PKI Client Authentication oppure enrollment Intune, LocalMachine\My, chiave privata RSA utilizzabile da SYSTEM |
| Rete per invio | HTTPS 443 all'Intake in contesto SYSTEM, senza interferenze TLS con mTLS; accesso PKI necessario secondo la catena |
| Server | Trust CA, binding device, autorizzazione Entra per Intune, schemi/tabelle e mapping pronti |

Nessuna dependency applicativa Intune e nessun requirement script aggiuntivo.
I prerequisiti di identita/certificato/rete sopra descritti sono operativi, non
controlli automatici nella pagina Requirements. Non includere certificati o chiavi
nel pacchetto. La verifica Graph e svolta dall'Intake: non servono credenziali Graph
sul client. Configurazione del proxy e accesso alla chiave devono funzionare come
SYSTEM, non soltanto come utente interattivo.

## 6. Comportamento installato e prova

Percorso: `C:\Program Files\LogCollector\CustomInventory\1.5.0`
(il codice usa il percorso Program Files del sistema, senza presupporre il disco C).

| Task SYSTEM in `\LogCollector\` | Azione |
|---|---|
| LogCollector-CustomInventory | Run-Inventory.ps1: raccolta e invio mercoledi/sabato alle 09:00 locali, ritardo casuale fino a 2 ore |
| LogCollector-CustomInventory-Spool | Sync-Spool.ps1: retry della coda ogni ora, primo trigger circa 5 minuti dopo installazione |

Con SubmissionEnabled=false entrambi sono disabilitati. L'installer non esegue
subito il collector. La disinstallazione rimuove solo questi task e conserva
file/spool; attendere la fine di eventuali task in esecuzione prima di installare
o disinstallare. Nessun task legacy viene modificato.

Assegnare inizialmente a un piccolo gruppo di dispositivi laboratorio, senza
assegnazioni contemporanee di vecchie versioni o collector equivalenti.
Le versioni condividono i nomi dei task: non sono installazioni affiancate.
Non disinstallare una vecchia versione dopo aver installato la nuova, perche
rimuoverebbe gli stessi task. Per aggiornamenti usare la stessa app e la procedura
contenuto + detection sopra descritta, non due app concorrenti. La nuova detection
rileva anche task che puntano ancora al percorso di una versione precedente.

Da Windows PowerShell a 64 bit elevato, nella cartella installata:

```powershell
.\Run-Inventory.ps1 -Preview
# Facoltativo: raccoglie e accoda localmente, senza HTTP da questa esecuzione.
.\Run-Inventory.ps1 -QueueOnly
```

Preview richiede identita Entra valida e restituisce conteggi senza accodare/inviare.
QueueOnly usa lo spool condiviso: altri sender abilitati sullo stesso endpoint
possono ritrasmettere quelle entry. Eseguire il test definitivo come SYSTEM.
Dopo attivazione esplicita e preparazione Azure:

```powershell
Start-ScheduledTask -TaskPath '\LogCollector\' -TaskName 'LogCollector-CustomInventory'
```

HTTP 202 significa presa in carico, non dati gia presenti in Log Analytics.
Controllare entrambe le tabelle e le query attese. Per problemi di installazione
consultare `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs`, in particolare
AppWorkload.log, AppActionProcessor.log e AgentExecutor.log, oltre allo stato dei
task in Task Scheduler. Evitare di esportare payload inventory nei log di supporto.

## 7. Diagnostica locale del pacchetto

Dalla versione 1.4.5 i task e l'installer scrivono log propri, distinti dai log IME:

```text
C:\ProgramData\LogCollector\Logs\CustomInventory\Install.log
C:\ProgramData\LogCollector\Logs\CustomInventory\Inventory.log
C:\ProgramData\LogCollector\Logs\CustomInventory\Spool.log
```

Sono log JSONL con RunId, UTC, PID e metadati selezionati. Install.log registra
anche la disinstallazione. I warning di raccolta sono identificati da fase/funzione
e riga sorgente; messaggi arbitrari, payload e risposte HTTP non vengono trascritti.
Preview e QueueOnly scrivono diagnostica ma mantengono le rispettive garanzie
di non invio. Packaging, detection e -WhatIf non generano log operativi.

Rotazione: 2 MiB/file, quattro archivi piu il file attivo per componente, archivi
conservati fino a 14 giorni e puliti durante le scritture. Circa 30 MiB massimi
complessivi per i tre componenti, piu i lock. Log e spool restano dopo uninstall.
Accesso limitato a SYSTEM/amministratori; percorsi non attendibili sono rifiutati.

Se i task non vengono eseguiti, aprire la sottocartella **LogCollector** di Task
Scheduler e controllare prima Settings.Enabled e Config.psd1: con
SubmissionEnabled=false i task sono presenti ma disabilitati. La detection
positiva di una configurazione disabilitata e intenzionale.
I log di raccolta compaiono solo quando Run-Inventory.ps1 viene effettivamente
eseguito; l'installazione da sola genera Install.log.

La creazione/scrittura del log deve riuscire: gli errori non sono ignorati.
Se il logger non puo essere inizializzato, consultare l'errore del processo nei
log IME; il pacchetto non finge una diagnosi persistente che non ha potuto scrivere.
