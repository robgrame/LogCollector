# ACI - Rilievi e piano di migrazione a LogCollector

**Data del rapporto: 2026-09-06.** Documento di ripresa basato sui rilievi forniti dall'analisi precedente, svolta in sola lettura. Questa stesura non comporta una nuova lettura degli script originali, non ne riproduce il codice e non include valori di credenziali.

**Stato:** il deployment Azure principale esiste; la migrazione dei client ACI e le estensioni di schema, tabelle e DCR necessarie per questi flussi **non sono ancora implementate**. Il modulo comune **LogCollector.Client 1.0.0** e predisposto nel repository, con manifest, packaging e guida [shared-client.md](shared-client.md). Questa disponibilita non equivale alla migrazione dei sender o alla distribuzione sui dispositivi.

## 1. Perimetro, provenienza e uso alla ripresa

La cartella sorgente analizzata era:

`C:\users\robgrame\OneDrive - 120mAGL\2share\ACI`

I rilievi censiscono **33 file PowerShell/CMD**, **17 script sender o loro varianti** e **13 nomi di destinazione**. Questi conteggi descrivono i file presenti, non dimostrano quali versioni siano distribuite o effettivamente attive. In particolare, non si deve assumere che la variante Secure Boot v1.5 sia quella in produzione.

Tutti i percorsi dei file cliente riportati sotto sono relativi alla cartella sorgente. I riferimenti di riga sono ancore dell'analisi precedente: servono a localizzare gli interventi futuri, ma possono slittare dopo modifiche. I nomi reali delle cartelle comprendono gli spazi: `Windows 11 Upgrade`, `Step 1`, `Step 2`, `Step 3`.

Il documento conserva i punti necessari a riprendere il lavoro senza ripetere la ricognizione: destinazioni, sender, raccolta dati da preservare, packaging, identita, vincoli del contratto, rischi e ordine degli interventi. Le verifiche ancora necessarie sono indicate come tali; non sono presentate come risultati gia ottenuti.

Gli script cliente originali non sono stati modificati o eseguiti e l'ambiente Azure non e stato alterato per questa attivita. Il rapporto non contiene valori di credenziali. I moduli comuni e la guida sono predisposti separatamente nel repository LogCollector, senza applicarli alle sorgenti ACI.

## 2. Baseline Azure esistente e limiti attuali

| Elemento | Rilievo autorevole al 2026-09-06 |
| --- | --- |
| Frontend | `https://logcollector-intake.azurewebsites.net/api/inventory` |
| Piano frontend | B1 |
| Worker | Flex, .NET 10 |
| Resource group | `LOGCOLLECTOR-RG` |
| Regione | ItalyNorth |
| Subscription | `b45c5b53-d8f3-4a4c-9fe5-5537818a9886` |
| Tenant della managed identity (MI) | `46b06a5e-8f7a-467b-bc9a-e776011fbb57` |
| Workspace | `LogCollector-law` |
| Unico mapping server attuale | `InventoryWindows_CL` -> `Custom-InventoryWindows_CL` |

Le 13 destinazioni ACI non sono abilitate semplicemente perche i client ne conoscono i nomi. Ogni aggiunta richiede una tabella con schema esplicito, stream DCR, mapping/trasformazioni DCR e configurazione coerente su **entrambe le applicazioni**, frontend e worker.

La DCR determina il workspace di destinazione. Il client non e autorizzato a scegliere workspace o destinazioni arbitrarie. Non confondere il nome completo della tabella nell'envelope, per esempio `DeviceInventory_CL`, con il nome dello stream DCR: il mapping oggi esistente e specifico di `InventoryWindows_CL` e non implica supporto degli altri nomi.

Questa baseline e registrata dai rilievi forniti, non da una nuova interrogazione dell'ambiente Azure.

## 3. Matrice completa file / destinazione

Le 17 righe seguenti rappresentano i sender o le varianti censite. Il primo sender alimenta due tabelle; piu varianti condividono la stessa destinazione.

| # | File relativo alla sorgente ACI | Destinazione legacy completa | Ancore di riga |
| --- | --- | --- | --- |
| 1 | `Custom Inventory\Invoke-CustomInventory.ps1` | `DeviceInventory_CL`, `AppInventory_CL` | Credenziali 32/35; helper 150-211; invii 546-547 |
| 2 | `PS-CheckSMBv1Status.ps1` | `DSK_SMBv1Status_CL` | Invio Write-Log 94; invio risultato 124; helper 133-173 |
| 3 | `SecureBoot\SecureBoot-LogAnalytics.ps1` | `SecureBootInventory_CL` | Get-LogAnalyticsSignature 143-178; sender 180-243; report 988-1101; invio 1130 |
| 4 | `SecureBoot\marco\SecureBoot-LogAnalytics.ps1` | `SecureBootInventory_CL` | Report 978-1091; invio 1120 |
| 5 | `SecureBoot\SecureBoot-ForceUpdate-LogAnalytics.ps1` | `SecureBootEnforcement_CL` | Default 50; Get-LogAnalyticsSignature 164-197; sender 199-255; Write-Telemetry 364-408; invio 404; ResumeTask 502-531 |
| 6 | `SecureBoot\marco\SecureBoot-ForceUpdate-LogAnalytics.ps1` | `RegistrySecureBootEnforcement_CL` | Default 55; invio 574 |
| 7 | `SecureBoot\marco\SecureBoot-ForceUpdate-LogAnalytics-Template.ps1` | `RegistrySecureBootEnforcement_CL` | Default 50; invio 569 |
| 8 | `SecureBoot\marco\SecureBoot-ForceUpdate-LogAnalytics-v1.5.ps1` | `RegistrySecureBootEnforcement_CL` | Default 240; sender 680-732; Write-Telemetry 947-1003; invio 999; Resume 1193-1248 |
| 9 | `Windows 11 Upgrade\PS-NotifyUpgradeComplete.ps1` | `DSK_W11UpgradeComplete_CL` | Default 32; sender 108-145 |
| 10 | `Windows 11 Upgrade\PS-ScheduleW11Upgrade.ps1` | `DSK_ScheduleW11Upgrade_CL` | Default 35; sender root 107-144 |
| 11 | `Windows 11 Upgrade\PS-ScheduleW11Upgrade - Copy.ps1` | `DSK_ScheduleW11Upgrade_CL` | Default 35; sender root 107-144; staging 351-408 |
| 12 | `Windows 11 Upgrade\PRA\Step 3\PS-ScheduleW11Upgrade.ps1` | `DSK_ScheduleW11Upgrade_CL` | Default 43; sender PRA 115-152 |
| 13 | `Windows 11 Upgrade\PS-SetCPUInfo.ps1` | `CPUInfo_CL` | Default 31; sender 107-144 |
| 14 | `Windows 11 Upgrade\PRA\Step 1\PS-StageW11Setup.ps1` | `WRK_W11UpgradeStaging_CL` | Default 42; sender 119-156 |
| 15 | `Windows 11 Upgrade\PRA\Step 2\PS-CopyW11FromWRK.ps1` | `DSK_W11UpgradeStaging_CL` | Default 41; sender 111-148 |
| 16 | `Windows 11 Upgrade\SedeCentrale\Step 1\PS-SC_CopyWindows11FromRepository.ps1` | `SC_CopyW11fromRepository_CL` | Default 46; sender 116-153 |
| 17 | `Windows 11 Upgrade\SedeCentrale\Step 2\PS-SC_ScheduleW11Upgrade.ps1` | `SC_ScheduleW11Upgrade_CL` | Default 43; sender 115-152 |

Nella colonna delle ancore, **default** indica la riga del valore predefinito di destinazione, non un intervallo temporale o un numero di tentativi.

Le 13 destinazioni uniche sono: `DeviceInventory_CL`, `AppInventory_CL`, `DSK_SMBv1Status_CL`, `SecureBootInventory_CL`, `SecureBootEnforcement_CL`, `RegistrySecureBootEnforcement_CL`, `DSK_W11UpgradeComplete_CL`, `DSK_ScheduleW11Upgrade_CL`, `CPUInfo_CL`, `WRK_W11UpgradeStaging_CL`, `DSK_W11UpgradeStaging_CL`, `SC_CopyW11fromRepository_CL`, `SC_ScheduleW11Upgrade_CL`.

**Distinzione critica:** il force-update nella cartella `SecureBoot` usa `SecureBootEnforcement_CL`; quelli nella cartella `SecureBoot\marco` usano `RegistrySecureBootEnforcement_CL`. Non uniformare queste destinazioni senza una decisione esplicita sul modello dati e sulla compatibilita delle query.

## 4. Dettagli di raccolta e punti di integrazione

### 4.1 Custom Inventory

In `Custom Inventory\Invoke-CustomInventory.ps1`, le righe 32/35 contengono riferimenti a credenziali legacy. Il blocco helper di trasporto e alle righe 150-211, mentre i due invii sono alle righe 546-547.

La funzione `Get-AzureADDeviceID`, righe 60-94, legge il CN del certificato individuato tramite `CloudDomainJoin\JoinInfo`. Questo e un meccanismo di ricavo dell'identificativo esistente: quel certificato **non e automaticamente la credenziale TLS** da usare con LogCollector. L'identita deve essere validata rispetto al contratto e al profilo di autenticazione scelto.

La raccolta delle applicazioni utente tramite HKU, righe 132-148, deve restare operativa. Il payload hardware alle righe 454-496 comprende dati annidati, tra cui `NetworkAdapters` e `DiskHealth`. I record applicativi alle righe 523-534 comprendono:

`AppName`, `AppVersion`, `AppInstallDate`, `AppPublisher`, `AppUninstallString`, `AppUninstallRegPath`.

L'intervento deve sostituire il trasporto mantenendo la raccolta e la semantica dei due flussi. Non sostituire integralmente il collector con uno nuovo che perda campi, dati annidati o applicazioni raccolte da HKU.

Le verifiche di successo basate sulla stringa `"200 :"` alle righe 555/564 sono incompatibili con il significato della nuova risposta `202`. Vanno adattate esplicitamente, senza interpretare l'accodamento come scrittura completata in Log Analytics. Preservare la semantica dell'uscita, inclusa l'ancora `Exit 0` a riga 573: un errore di telemetria non deve diventare implicitamente un errore della raccolta o della remediation.

### 4.2 Stato SMBv1

`PS-CheckSMBv1Status.ps1` invia sia diagnostica tramite `Write-Log` a riga 94 sia il risultato principale a riga 124, con helper alle righe 133-173.

Il record diagnostico contiene `TimeGenerated`, `MachineName`, `Level`, `Message`, `ScriptName`. Il record SMB contiene campi di stato booleani e `CheckType`. Questi sono due tipi di record distinti, anche se condividono `DSK_SMBv1Status_CL`: lo schema e il mapping devono conservarne la distinzione.

Gli errori di logging e il risultato del controllo SMB devono rimanere separati. Per la migrazione, aggregare la telemetria compatibile in batch invece di generare una richiesta per ciascun log, evitando cosi un lookup Graph per ogni messaggio. L'aggregazione non deve eliminare il risultato principale ne alterare il comportamento del controllo.

### 4.3 Inventario Secure Boot

I due reporter, root e `marco`, alimentano `SecureBootInventory_CL`. Le ancore specifiche sono nella matrice: non applicare automaticamente gli offset della versione root alla variante `marco`.

I campi `PKCertificates`, `KEKCertificates`, `DBCertificates` e `SecureBootUpdateEvents` sono **stringhe contenenti JSON**. La migrazione deve preservarne forma e contenuto, oppure prevedere una trasformazione di schema esplicita e compatibile con le query. Non confonderli con gli oggetti annidati di Custom Inventory.

I certificati UEFI presenti nell'inventario non sono credenziali TLS client. Nessun certificato raccolto come dato di inventario deve essere promosso implicitamente a credenziale di autenticazione.

### 4.4 Enforcement Secure Boot e varianti

La versione root ha `Write-Telemetry` alle righe 364-408, invio a riga 404 e ripresa tramite task alle righe 502-531. Le versioni `marco` usano la diversa destinazione indicata in matrice.

Per la variante v1.5 sono rilevanti il rilancio IME in PowerShell a 64 bit, BitLocker, lo stato persistente, le riprese dopo reboot, i retry e la cache degli eventi. Il timeout di telemetria e di **30 secondi**, con ancore alle righe 305/725. `TPMWmiEvents` e una stringa JSON.

Le varianti force-update effettuano autocopia e ripresa attraverso i riavvii. L'integrazione del modulo deve seguire lo stesso percorso di packaging persistente; non basta importarlo dalla cartella di distribuzione iniziale.

Lo stato firmware, lo stato di reboot e la cache eventi **non sono uno spool della telemetria**. Non usarli come prova che un evento sia stato consegnato o che esista gia una coda di ritrasmissione. Un drenaggio della telemetria non deve rieseguire modifiche firmware, operazioni BitLocker o remediation.

La variante realmente attiva resta da verificare. Le proprieta osservate nella v1.5 non vanno attribuite senza riscontro alle altre versioni o a tutti i dispositivi.

### 4.5 Windows 11 Upgrade

I nove sender del gruppo `Windows 11 Upgrade` usano il formato evento legacy `Write-Log`: `TimeGenerated`, `MachineName`, `Level`, `Message`, `ScriptName`. L'identita attuale e basata sul solo hostname. Non dedurre dal nome `CPUInfo_CL` l'esistenza di un payload CPU strutturato diverso dal formato rilevato.

Il passaggio al contratto LogCollector richiede un vero `entraDeviceId` GUID; il solo hostname non soddisfa tale requisito. La maggior parte degli errori `Write-Log` e non fatale: preservare questa separazione dagli esiti delle operazioni di upgrade.

I retry delle copie SMB sono **10 tentativi a distanza di 300 secondi**, con uscita `1618` dopo l'esaurimento. Non sono retry HTTP e non costituiscono una politica di consegna della telemetria. Non modificarli per adattarli al nuovo sender.

Nel copy-scheduler, righe 351-408, vengono predisposti lo script Notify e `SetupComplete.cmd`. Quest'ultimo, a riga 1, invoca Notify dopo l'upgrade. Il pacchetto dei moduli deve quindi essere ancora disponibile nel contesto post-upgrade, non soltanto durante lo staging.

I wrapper `start.cmd` invocano le operazioni stage/copy con modalita Create/Delete e non hanno un invio HTTP proprio. Mantenerne la funzione di orchestrazione senza aggiungere una migrazione del sender dove non esiste.

## 5. Wrapper, task pianificati e persistenza del pacchetto

| Wrapper o percorso di esecuzione | Comportamento rilevato | Conseguenza per la migrazione |
| --- | --- | --- |
| `Custom Inventory\PS-ScheduleScript.ps1` | Copia un solo PS1 in `C:\temp\ACIInformatica`; salta il file gia presente alle righe 19-21; esecuzione SYSTEM, mercoledi/sabato alle 09:00, RandomDelay di 5 minuti, ancora 165 | La logica di skip puo lasciare in uso un vecchio script con chiave incorporata. Il rollout deve aggiornare il pacchetto persistente, non solo la sorgente |
| `SecureBoot\PS-ScheduleScript.ps1` | Copia il solo reporter in `C:\temp\SecureBootScripts`; esecuzione giornaliera alle 11:00, RandomDelay di 5 minuti, ancora 164; WorkspaceId/Key globali alle righe 10-11 e passati come argomenti del task a riga 171 | Distribuire anche i moduli; rimuovere le credenziali dagli argomenti e dalle vecchie copie degli script |
| Force-update Secure Boot | Autocopia e resume tra riavvii | I moduli devono viaggiare con il pacchetto nel percorso persistente effettivamente usato dal resume |
| Staging upgrade / SetupComplete | Esecuzione di Notify dopo upgrade | Il percorso di import e tutti i moduli necessari devono sopravvivere allo staging e al cambio di contesto |

I nomi e i percorsi dei task possono essere usati dagli script di detection: conservarli oppure trattarne ogni cambiamento come intervento coordinato su tutti i riferimenti. Non rinominarli incidentalmente durante la sostituzione del sender.

Per LogCollector e stato concordato un `RandomDelay` di **2 ore**, ma tale impostazione **non e applicata agli script sorgente ACI**, che usano 5 minuti nei wrapper citati. Non dichiararla gia distribuita e non estenderla arbitrariamente all'avvio di upgrade, alle remediation o alle relative notifiche.

I percorsi legacy sotto `C:\temp` descrivono il packaging esistente, non una raccomandazione per lo spool nuovo. Lo spool deve avere protezioni e collocazione proprie, come descritto sotto.

## 6. File senza invio HTTP proprio

Non e richiesta una sostituzione diretta del sender nei seguenti gruppi, salvo adeguamenti necessari a packaging o mock:

| Gruppo | File o famiglie rilevati |
| --- | --- |
| Root | `PS-Detect`, `PS-RebootComputer`, `Test-WUNetCheck-Final` |
| Windows 11 Upgrade | `ACI-CheckClientOnlineStatus`, `test_ping_scan`, detection PRA/SC, `verify-not-exists`, wrapper CMD |
| Secure Boot | Test e strumenti senza invio proprio |

Questa esclusione riguarda soltanto il trasporto: detection, percorsi, parametri di orchestrazione e dipendenze post-reboot possono richiedere adeguamenti coordinati. Non attribuire a questi file un sender inesistente.

## 7. Identita, certificati e gestione delle credenziali

### 7.1 Credenziali legacy

Nei file e negli argomenti dei task sono incorporate chiavi workspace. **Non riportarne mai i valori** in documentazione, log, test, issue o patch. Dopo la migrazione occorre una rotazione coordinata, che tenga conto di tutti i consumer legacy ancora attivi e delle copie persistenti degli script.

La rimozione dal file sorgente non rimuove automaticamente una chiave da un task gia registrato o da uno script copiato in precedenza. Il caso di skip del file esistente in Custom Inventory e particolarmente critico. Pianificare aggiornamento delle copie, pulizia degli argomenti e rotazione con evidenza del completamento, senza registrare i segreti rimossi.

Il nuovo flusso non richiede Function key o segreti condivisi lato client. Richiede invece un certificato client idoneo e la disponibilita della relativa chiave privata nel contesto di esecuzione autorizzato; non e necessario leggerne o esportarne il valore per documentare o progettare la migrazione.

### 7.2 Profili PKI e Intune

Il profilo PKI applica controlli e binding relativi a root/chain, EKU, scadenza e revoca. Il profilo Intune aggiunge un lookup Entra obbligatorio nel tenant della MI: la corrispondenza del dispositivo deve essere esatta e il dispositivo deve risultare abilitato.

Il mapping Intune dell'OID `1.2.840.113556.5.25` e ereditato dal riferimento esistente: **deve essere verificato in un pilot con un certificato reale**. Non considerare la presenza dell'OID, da sola, una prova end-to-end di funzionamento.

La configurazione distribuita imposta `ClientCert__SkipIntuneRevocationCheck=true`, perche la catena Intune configurata non pubblica endpoint CRL/OCSP, e mantiene `ClientCert__CheckRevocation=true` per la PKI. I parametri Bicep corrispondenti sono `skipIntuneRevocationCheck` e `checkRevocation`. Registrare la differenza come configurazione attuale, non come regola generale da copiare senza valutazione.

Il controllo Graph si applica solo al percorso Intune e richiede il dispositivo Entra esistente e abilitato. Non attesta compliance o gestione Intune corrente: il ritiro dell'enrollment potrebbe lasciare abilitato il record Entra.

Un certificato ricavato da `CloudDomainJoin\JoinInfo`, i certificati UEFI inventariati e il certificato selezionato per HTTPS mTLS sono concetti distinti. Il binding fra identita dichiarata e certificato deve rispettare i controlli server del profilo adottato.

## 8. Contratto di trasporto e compatibilita dati

### 8.1 Envelope

| Campo | Vincolo |
| --- | --- |
| `envelopeVersion` | Valore `LOGCOLLECTOR-INVENTORY-V1` |
| `tableName` | Nome completo della tabella, incluso suffisso `_CL`, registrato lato server |
| `entraDeviceId` | GUID del dispositivo Entra; non hostname o identificativo inventato |
| `collectedAtUtc` | Istante di raccolta in UTC |
| `records` | Array non vuoto di oggetti |
| `deviceName`, `intuneDeviceId`, `source` | Facoltativi |
| `properties` | Facoltativo; massimo 32 proprieta stringa |

La richiesta viaggia su HTTPS con mTLS. La firma usa il protocollo `IDA-SIGNATURE-V1` sui **byte UTF-8 esatti** del corpo. Timestamp e nonce devono essere nuovi per ogni tentativo. Non ricostruire il JSON durante la ritrasmissione se questo modifica i byte del corpo.

Una risposta **`202` significa accodato**, non scritto definitivamente in Log Analytics. La validazione end-to-end deve includere il percorso worker/DCR e la presenza del dato in tabella, non fermarsi alla risposta HTTP.

### 8.2 Limiti e batching

Il limite totale della richiesta e **4 MiB**, con massimo **50.000 record**. Il worker crea chunk da **850 KiB** e rifiuta le righe singolarmente troppo grandi.

Serve uno split esplicito dei batch lato client; non assumere che i moduli esistenti lo eseguano automaticamente. La suddivisione deve rispettare sia il limite in byte UTF-8 dell'envelope completo sia il numero di record. I chunk del worker non rendono valido un envelope client oltre limite e non possono risolvere una singola riga sovradimensionata.

Per dati annidati e stringhe JSON, misurare la serializzazione effettiva, inclusi escaping e caratteri non ASCII. Evitare troncamenti silenziosi e perdita di profondita JSON per rientrare nei limiti.

### 8.3 Campi di proprieta server e schema legacy

I campi `TimeGenerated`, `CollectedAtUtc`, `EntraDeviceId`, `DeviceName`, `IntuneDeviceId`, `Source`, `CorrelationId`, `RecordIndex` sono di proprieta server.

Preservare l'istante originale dell'evento legacy in **`EventTimeUtc` per ogni record**. Non affidarsi a `TimeGenerated` nel payload per conservare quel valore, e non sostituire l'istante dell'evento con quello di un successivo retry.

Le colonne tipizzate legacy con suffissi `_s`, `_b`, `_d` e le query che le usano richiedono mapping DCR espliciti. Per ogni tabella occorre documentare tipo origine, tipo destinazione e compatibilita delle query, compresi i record eterogenei SMB, i booleani, i dati annidati e le stringhe JSON Secure Boot.

La registrazione dei 13 nomi non e una migrazione degli schemi. Prima di integrare i sender definire come preservare ciascun campo e come rendere visibile un eventuale scarto o errore di trasformazione.

## 9. Moduli riutilizzabili, facade e spool

I quattro moduli esistenti riutilizzabili nel repository LogCollector sono:

| Modulo | Percorso |
| --- | --- |
| DeviceIdentity | `src\Client\DeviceIdentity.psm1` |
| RequestSigning | `src\Client\RequestSigning.psm1` |
| InventoryClient | `src\Client\InventoryClient.psm1` |
| InventorySpool | `src\Client\InventorySpool.psm1` |

La facade disponibile si importa da `src\Client\LogCollector.Client.psd1`. Espone `Send-LogCollectorData`, `Sync-LogCollectorSpool` e `Get-LogCollectorSpoolPath`, oltre alle funzioni gia esistenti per identita, certificato, firma ed envelope. `scripts\Publish-ClientModule.ps1` produce il pacchetto versionato. [shared-client.md](shared-client.md) descrive il contratto aggiornato e gli esempi.

**Rilievo storico e risoluzione nel modulo:** durante l'analisi iniziale `Invoke-InventorySubmission` richiedeva gia il certificato, quindi la sua assenza prima della chiamata impediva lo spool. La facade 1.0.0 ora gestisce esplicitamente l'assenza attesa del certificato e conserva l'envelope, se l'identita Entra e disponibile. Supporta inoltre `-QueueOnly` senza ricerca certificato o HTTP. Errori locali inattesi continuano a propagarsi e non vengono mascherati. Questa correzione non e ancora integrata negli script ACI.

Se manca l'Entra device ID, non generare un GUID fittizio e non usare l'hostname al suo posto. Rendere osservabile il problema secondo la politica di telemetria non fatale prevista dal chiamante; il trattamento dei dati non ancora associabili a un'identita valida deve essere deciso esplicitamente, non mascherato da una richiesta apparentemente valida.

Lo spool deve mantenere il corpo invariato e firmare di nuovo ogni tentativo con timestamp e nonce freschi. Deve essere **specifico per endpoint**, in un percorso protetto da ACL per SYSTEM e amministratori, non in `%TEMP%` o in un percorso legacy insicuro. Non effettuare riparazioni opportunistiche dello spool legacy che promuovano contenuti non attendibili a richieste firmate.

Gli eventi una tantum, post-upgrade o post-reboot necessitano di un drenaggio indipendente dello spool: la loro consegna non puo dipendere dalla riesecuzione della remediation che li ha generati. Stato firmware/reboot e spool di telemetria devono restare separati.

L'errore del trasporto deve essere rilevabile ma non deve cambiare silenziosamente un successo della remediation in un errore operativo. Preservare i codici di uscita, i comportamenti non fatali e le aspettative di detection dei singoli chiamanti.

## 10. Sequenza di integrazione proposta

Questa e una sequenza di lavoro futuro, non un elenco di modifiche gia applicate.

1. **Confermare il perimetro effettivo.** Identificare le varianti attive, i task realmente distribuiti, i percorsi persistenti e i consumer delle chiavi legacy. Confermare tenant, workspace e profilo certificato previsti. Non assumere v1.5 attiva o equivalenza delle destinazioni root/marco.
2. **Registrare tabelle e contratti dati.** Definire i 13 schemi, stream e mapping DCR, inclusi tipi legacy, `EventTimeUtc` e campi annidati/stringhe JSON. Configurare entrambi gli applicativi. La DCR deve mantenere il controllo del workspace.
3. **Consolidare modulo comune e packaging.** Allinearsi al contratto pubblicato in `shared-client.md`; coprire certificato assente prima della chiamata, gestione dell'identita, firma, batching esplicito, spool protetto e drenaggio autonomo. Rendere il pacchetto disponibile per SYSTEM e dopo reboot/upgrade.
4. **Integrare prima il pilot SMB.** Sostituire il helper di invio mantenendo separati diagnostica e risultato; aggregare i log compatibili, senza un lookup Graph per ogni messaggio. Eseguire un pilot reale positivo fino alla tabella prima di estendere il rollout.
5. **Integrare Custom Inventory.** Conservare raccolta HKU, hardware annidato e tutti i campi applicativi; usare le due destinazioni; sostituire i controlli `"200 :"`; correggere il rollout che salta le copie preesistenti.
6. **Integrare Windows 11 Upgrade.** Mantenere il formato evento e la non fatalita dei log; aggiungere identita valida; distribuire i moduli con Notify e SetupComplete; non alterare i retry SMB, il codice `1618` o la temporizzazione dell'upgrade.
7. **Integrare Secure Boot per ultimo.** Trattare separatamente reporter e force-update, root e `marco`; aggiornare autocopia/resume e packaging senza regressioni di IME 64 bit, BitLocker, cache eventi, timeout, stato e riavvii.
8. **Completare la dismissione legacy.** Aggiornare copie persistenti e argomenti dei task, verificare i consumer residui, quindi ruotare coordinatamente le chiavi. Registrare gli esiti senza valori segreti e senza dichiarare completata la consegna sulla sola base di `202`.

## 11. Piano di validazione per la migrazione futura

Le attivita di questa sezione sono **da eseguire** durante l'implementazione. Non sono state svolte nell'ambito della redazione del rapporto.

| Area | Casi da coprire | Risultato atteso |
| --- | --- | --- |
| Sender e risposte | Mock del sender; `202`; rifiuti di autenticazione; errori di trasporto | `202` distinto dal commit in tabella; telemetria non fatale dove previsto; errore osservabile |
| Offline e spool | Assenza rete, certificato assente prima della chiamata, ripresa e drenaggio separato | Corpo preservato; nessuna remediation rieseguita per consegnare dati; nessun successo simulato |
| Firma e certificati | Byte esatti, timestamp/nonce nuovi, rinnovo certificato, root/chain/EKU/scadenza/revoca | Firma coerente con il corpo; selezione e binding conformi al profilo |
| Intune / Entra | GUID reale, corrispondenza esatta, dispositivo abilitato nel tenant MI, OID su certificato reale | Identita verificata; nessun fallback a hostname o GUID inventato |
| JSON e dimensioni | Caratteri non ASCII, profondita JSON, payload annidati, 4 MiB, 50.000 record, riga troppo grande per 850 KiB | Split esplicito dove possibile; errore esplicito per righe incompatibili; nessuna perdita o troncamento silenzioso |
| Schemi e query | Tutte le 13 destinazioni, tipi `_s`/`_b`/`_d`, `EventTimeUtc`, dati SMB eterogenei | Mapping DCR e query compatibili con il contratto deciso |
| Raccolta Custom Inventory | HKU, `NetworkAdapters`, `DiskHealth`, sei campi applicativi elencati | Raccolta preservata, senza sostituzione riduttiva del collector |
| Packaging e contesti | Windows PowerShell 5.1 sotto SYSTEM, copia preesistente, task, SetupComplete, post-reboot | Moduli e spool disponibili nel percorso protetto corretto; detection e task compatibili |
| Regressioni operative | IME 64 bit, BitLocker, resume, cache eventi, timeout 30 secondi della v1.5, retry SMB e codici di uscita | Nessuna modifica accidentale delle operazioni o del loro esito |
| Pilot live | Certificato reale valido, frontend, coda, worker, DCR, record in tabella | Evidenza positiva end-to-end; non solo risposta `202` |

I test esistenti sotto `SecureBoot\marco\Tests` relativi a sender, firma e mock di `Invoke-RestMethod` richiederanno aggiornamenti coerenti con il nuovo trasporto. Conservare le coperture di regressione IME e reboot. Non aggiornare i mock in modo da nascondere una perdita di comportamento.

Il **pilot live positivo con certificato reale e ancora pendente**. In particolare resta da provare il mapping Intune dell'OID e il percorso di ingestione completo con gli schemi ACI.

## 12. Rischi prioritari e criteri di arresto del rollout

| Rischio | Segnale concreto | Condizione necessaria prima di procedere |
| --- | --- | --- |
| Destinazioni non abilitate | Server attuale limitato a `InventoryWindows_CL` | Tabelle, stream e mapping ACI presenti e coerenti su entrambe le app |
| Credenziali legacy residue | File copiati saltati; WorkspaceId/Key negli argomenti dei task | Aggiornamento effettivo delle copie e rimozione dagli argomenti; rotazione coordinata |
| Identita errata o certificato non idoneo | Solo hostname; certificato JoinInfo/UEFI confuso con mTLS | GUID reale e pilot di autenticazione/binding con certificato reale |
| Perdita di dati di raccolta | Collector sostituito integralmente; JSON appiattito o troncato | Parita dei campi e forme dati prevista dagli schemi |
| Perdita di eventi una tantum | Spool subordinato al certificato o al rerun della remediation | Accodamento gestito esplicitamente e drenaggio indipendente |
| Consegna dichiarata troppo presto | `202` interpretato come commit Log Analytics | Evidenza nel percorso worker/DCR e nella tabella |
| Regressione di upgrade/firmware | Ritardi estesi a 2 ore, moduli mancanti al resume, exit code alterati | Packaging post-reboot valido e semantica operativa preservata |
| Variante sbagliata | Tutti i force-update trattati come v1.5 o con la stessa tabella | Inventario delle versioni effettive e trattamento distinto root/marco |
| Spool non attendibile | Uso di TEMP o riuso non protetto di file legacy | Percorso endpoint-specifico e ACL SYSTEM/amministratori; nessuna riparazione insicura |

## 13. Checklist di stato e punto di ripresa

| Stato | Attivita |
| --- | --- |
| Completata nell'analisi precedente | Ricognizione in sola lettura: 33 file, 17 sender/varianti, 13 destinazioni e ancore riportate |
| Completata con questo documento | Conservazione dei rilievi, rischi, contratto e sequenza di ripresa, senza codice sorgente o segreti |
| Esistente secondo i rilievi | Deployment Azure principale con il solo mapping `InventoryWindows_CL` -> `Custom-InventoryWindows_CL` |
| Predisposta nel repository | Facade LogCollector.Client 1.0.0, manifest, packaging e guida `shared-client.md`; non ancora distribuita/integrata sui client ACI |
| Da fare | Conferma delle varianti attive, tenant/workspace e task/copie realmente distribuiti |
| Da fare | Schemi delle 13 tabelle, stream/mapping DCR e configurazioni su entrambe le applicazioni |
| Da fare | Integrazione sender: SMB, Custom Inventory, Windows 11 Upgrade, Secure Boot |
| Da integrare/distribuire | Pacchetto persistente e spool protetto del modulo; task di drenaggio autonomo e gestione degli esiti nei singoli script |
| Da fare | Aggiornamento test e verifiche di compatibilita dati, task, IME, BitLocker, reboot e codici di uscita |
| Pendente | Pilot positivo con certificato reale e conferma di presenza dati in Log Analytics |
| Da fare dopo migrazione coordinata | Rimozione delle credenziali legacy residue e rotazione delle chiavi |

**Punto di ripresa:** partire dalla conferma delle varianti e dal contratto del modulo comune, quindi definire gli schemi e abilitare il pilot SMB. Non dichiarare completata la migrazione Azure/client sulla base di questo rapporto, della sola esistenza del deployment principale o della preparazione della facade.
