# Percorsi LogCollector Core e LogCollector.Client

Questo documento descrive i percorsi Windows usati da **LogCollector Core 1.11.1**
e dal modulo condiviso **LogCollector.Client 1.11.1**. I percorsi sono espressi
con variabili di sistema: l'implementazione non presume che Windows sia installato
su `C:`.

## Variabili usate

| Variabile | Significato tipico su Windows x64 |
|---|---|
| `%ProgramW6432%` | Percorso Program Files nativo x64 usato nelle command line Intune |
| `%ProgramData%` | `C:\ProgramData` |
| `%SystemRoot%` | `C:\Windows` |
| `<CustomerName>` | Nome configurato nel pacchetto Core, ad esempio `MSLabs` |
| `<ApplicationName>` | Nome dello script o applicazione che usa il logging condiviso |
| `<EndpointHash>` | SHA-256 esadecimale della URL completa e normalizzata dell'Intake |

Il codice risolve Program Files con
`[Environment]::GetFolderPath('ProgramFiles')`. Installer, detection e task devono
quindi essere eseguiti in **PowerShell a 64 bit**; un processo a 32 bit non è
supportato. In Intune usare `Sysnative` per avviare PowerShell nativo e impostare
**Run script as 32-bit process on 64-bit clients = No**.
Una detection eseguita erroneamente a 32 bit cerca sotto `Program Files (x86)` e
restituisce non installato, potenzialmente causando reinstallazioni ripetute.

## Struttura installata

```text
%ProgramW6432%\WindowsPowerShell\Modules\LogCollector.Client\
    LogCollector.Client.psd1
    LogCollector.Client.psm1
    EndpointConfiguration.psm1
    CMTraceLogging.psm1
    DeviceIdentity.psm1
    RequestSigning.psm1
    InventoryClient.psm1
    InventorySpool.psm1
    Uninstall.ps1
    Core.Provisioning.psm1
```

Il percorso fisico è intenzionalmente **stabile e non versionato**. La versione è
registrata in `LogCollector.Client.psd1`; un upgrade sostituisce atomicamente
l'intera directory. Gli script devono importare:

```text
%ProgramW6432%\WindowsPowerShell\Modules\LogCollector.Client\LogCollector.Client.psd1
```

oppure usare:

```powershell
Import-Module LogCollector.Client
```

Non devono aggiungere `\<versione>` al percorso.

## Configurazione e dati condivisi

```text
%ProgramData%\<CustomerName>\LogCollector\
    Config\
        Endpoint.psd1
    Logs\
        LogCollector.log
        LogCollector.log.1 ... LogCollector.log.5
        LogCollector.log.lock
    SharedSpool\
        <EndpointHash>\
            yyyyMMddTHHmmssfff-<guid>.json
            .drain.lock
            quarantine\
                <nome-entry>.json.<motivo>
    State\
        <stato applicazione>.json
```

| Percorso | Proprietario | Utilizzo |
|---|---|---|
| `%ProgramData%\<CustomerName>\LogCollector` | Core | Radice dati condivisa restituita da `Get-LogCollectorDataRoot` |
| `...\Config\Endpoint.psd1` | Core | Endpoint, ambiente, cliente, stato di submission e criteri certificato/PKI |
| `...\Logs\LogCollector.log` | Installer Core | Log CMTrace persistente di installazione e upgrade |
| `...\SharedSpool` | Client condiviso | Radice delle code offline condivise da tutti gli script |
| `...\SharedSpool\<EndpointHash>` | Client condiviso | Coda isolata per la specifica URL di Intake |
| `...\SharedSpool\<EndpointHash>\quarantine` | Client condiviso | Entry corrotte o rifiutate permanentemente, mai ritentate |
| `...\State` | Script applicativi | Stato persistente specifico degli script; Core non ne interpreta i file |

`Endpoint.psd1` non contiene segreti. La directory, il file di configurazione, il
modulo, lo spool e lo stato sono protetti contro scrittura o sostituzione da parte
di utenti non amministrativi. I reparse point non sono accettati.

### Esempio MSLabs

```text
C:\Program Files\WindowsPowerShell\Modules\LogCollector.Client\
C:\ProgramData\MSLabs\LogCollector\Config\Endpoint.psd1
C:\ProgramData\MSLabs\LogCollector\Logs\LogCollector.log
C:\ProgramData\MSLabs\LogCollector\SharedSpool\<EndpointHash>\
C:\ProgramData\MSLabs\LogCollector\State\
```

## Logging condiviso per gli altri script

Gli script che importano `LogCollector.Client` possono usare `Write-CMTraceLog`.
Il percorso standard è:

```text
%ProgramData%\<CustomerName>\<ApplicationName>\Logs\<ApplicationName>.log
```

Esempio:

```text
C:\ProgramData\MSLabs\W11Upgrade\Logs\W11Upgrade.log
```

Il log attivo usa per impostazione predefinita un massimo di 5 MiB e conserva
cinque archivi:

```text
<ApplicationName>.log
<ApplicationName>.log.1
...
<ApplicationName>.log.5
<ApplicationName>.log.lock
```

Il file `.lock` coordina scritture e rotazioni concorrenti. Se la configurazione
Core non è disponibile, il solo helper di logging usa `LogCollector` come nome
cliente di fallback:

```text
%ProgramData%\LogCollector\<ApplicationName>\Logs\<ApplicationName>.log
```

L'installer Core usa inoltre un fallback diagnostico specifico quando non riesce
ancora a leggere o validare il `CustomerName` dal package:

```text
%ProgramData%\LogCollector\LogCollector\Logs\LogCollector.log
```

Questo è un percorso attivo di troubleshooting per installazioni fallite, non un
layout legacy da migrare.

## Percorsi temporanei durante installazione e rollback

Durante una sostituzione atomica possono esistere brevemente directory sorelle:

```text
%ProgramW6432%\WindowsPowerShell\Modules\LogCollector.Client.staging-<guid>
%ProgramW6432%\WindowsPowerShell\Modules\LogCollector.Client.retired-<guid>
%ProgramW6432%\WindowsPowerShell\Modules\LogCollector.Client.failed-<guid>
```

Non sono percorsi operativi e non devono essere usati dagli script. L'installer li
rimuove al termine o li usa esclusivamente per ripristinare la versione precedente.

Durante la scrittura atomica della configurazione possono inoltre comparire
temporaneamente:

```text
%ProgramData%\<CustomerName>\LogCollector\Config\Endpoint.<guid>.tmp
%ProgramData%\<CustomerName>\LogCollector\Config\Endpoint.psd1.rollback-<guid>
```

## Percorsi legacy

Le versioni precedenti potevano usare:

```text
%ProgramData%\LogCollector\Config\Endpoint.psd1
%ProgramData%\LogCollector\SharedSpool
%ProgramData%\LogCollector\State
```

L'installer corrente migra `SharedSpool` e `State` nella radice cliente. Non
sovrascrive né ignora una collisione: se il percorso di destinazione contiene già
un file con lo stesso nome, la migrazione termina con errore e il conflitto deve
essere risolto dall'amministratore. A quel punto il nuovo modulo e la nuova
configurazione sono già stati verificati e attivati; i dati sorgente restano
disponibili per ripetere la migrazione in sicurezza. Dopo una migrazione riuscita
viene rimossa la configurazione legacy validata.

Lo stesso processo gestisce un cambio di `CustomerName`: il Core cerca una
precedente configurazione attendibile sotto
`%ProgramData%\<OldCustomerName>\LogCollector`, migra `SharedSpool` e `State` nella
nuova radice e rimuove il vecchio `Endpoint.psd1`. Se trova più di una precedente
configurazione cliente, l'installazione viene rifiutata finché le installazioni
obsolete non vengono rimosse. I percorsi precedenti non devono essere usati per
nuovi deployment.

Un chiamante esplicito privo di configurazione Core può ancora ottenere il fallback
di compatibilità:

```text
%ProgramData%\LogCollector\LogCollector\SharedSpool\<EndpointHash>
```

Questo fallback non rappresenta la configurazione di produzione: i package gestiti
devono dipendere da Core e usare la radice cliente.

## Effetto della disinstallazione

| Comando | Modulo | Configurazione risolta | Spool risolto |
|---|---:|---:|---:|
| `Uninstall.ps1 -ExpectedVersion <versione>` | Rimosso | Conservata | Conservato |
| Aggiunta di `-RemoveConfiguration` | Rimosso | Rimossa | Conservato |
| Aggiunta di `-RemoveSpool` | Rimosso | Conservata salvo altro switch | Rimosso |

La directory condivisa
`%ProgramW6432%\WindowsPowerShell\Modules` non viene mai rimossa dal package.

I due switch rimuovono il percorso restituito dalla configurazione Core valida.
Se la configurazione non può essere letta, l'uninstaller usa soltanto i fallback
legacy `%ProgramData%\LogCollector\Config\Endpoint.psd1` e
`%ProgramData%\LogCollector\SharedSpool`; eventuali dati sotto una radice cliente
non risolvibile restano sul dispositivo e devono essere verificati esplicitamente
prima di considerarne completata la rimozione.
