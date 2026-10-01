# Percorsi Custom Inventory

Questo documento descrive i percorsi usati da **Custom Inventory 1.9.1**. Il
package dipende da **LogCollector Core 1.11.1 o successivo** e non possiede una
seconda configurazione di endpoint, certificato, cliente o spool.

## Installazione

```text
%ProgramW6432%\<CustomerName>\CustomInventory\
    Version
    Config.psd1
    Inventory.Collection.psm1
    Inventory.Runtime.psm1
    Inventory.Logging.psm1
    Run-Inventory.ps1
    Sync-Spool.ps1
    Install.ps1
    Uninstall.ps1
    Detect.ps1
    README.md
```

Esempio MSLabs:

```text
C:\Program Files\MSLabs\CustomInventory\
```

Il percorso è stabile e non contiene la versione. `Version` e
`Config.psd1.PackageVersion` identificano il package installato.

`Config.psd1` contiene soltanto impostazioni specifiche del collector:

- nomi delle tabelle `DeviceInventory_CL` e `AppInventory_CL`;
- attivazione della raccolta device e applicazioni;
- numero massimo di tentativi;
- timeout HTTP;
- versione del package.

Non contiene `FrontendUrl`, `CustomerName`, ambiente, stato di submission,
thumbprint, selettori certificato o criteri CA.

## Dipendenze lette dal Core

| Dato | Percorso |
|---|---|
| Modulo condiviso | `%ProgramW6432%\WindowsPowerShell\Modules\LogCollector.Client\LogCollector.Client.psd1` |
| Configurazione protetta | `%ProgramData%\<CustomerName>\LogCollector\Config\Endpoint.psd1` |
| Spool condiviso | `%ProgramData%\<CustomerName>\LogCollector\SharedSpool\<EndpointHash>` |

Custom Inventory non crea una propria directory di spool. `Run-Inventory.ps1` e
`Sync-Spool.ps1` usano lo stesso bucket endpoint-specifico degli altri sender
LogCollector.

## Log

Percorso primario:

```text
%ProgramData%\<CustomerName>\CustomInventory\Logs\
    Install.log
    Install.log.1 ... Install.log.4
    .Install.lock
    Inventory.log
    Inventory.log.1 ... Inventory.log.4
    .Inventory.lock
    Spool.log
    Spool.log.1 ... Spool.log.4
    .Spool.lock
```

Percorso fallback:

```text
%ProgramData%\LogCollectorFallback\<CustomerName>\CustomInventory\Logs\
```

Esempio MSLabs:

```text
C:\ProgramData\MSLabs\CustomInventory\Logs\Install.log
C:\ProgramData\MSLabs\CustomInventory\Logs\Inventory.log
C:\ProgramData\MSLabs\CustomInventory\Logs\Spool.log

C:\ProgramData\LogCollectorFallback\MSLabs\CustomInventory\Logs\
```

| File | Contenuto |
|---|---|
| `Install.log` | Installazione, aggiornamento e disinstallazione dei task |
| `Inventory.log` | Raccolta, preview, accodamento e invio dei due flussi Inventory |
| `Spool.log` | Drain periodico e ritrasmissione delle entry condivise |

I log sono JSON Lines, hanno limite predefinito di 2 MiB ciascuno e conservano
quattro archivi. Durante una scrittura la manutenzione elimina qualsiasi file
attivo o archiviato più vecchio di 14 giorni o già oltre il limite dimensionale;
la normale rotazione conserva poi gli slot previsti. I file `.lock` non sono log
e servono a serializzare scrittura e rotazione.

Il fallback viene usato solo quando il percorso primario non supera i controlli
di sicurezza o non è disponibile. Non contiene un segmento di versione, così gli
aggiornamenti continuano a scrivere nello stesso percorso.

## Scheduled Task

I task risiedono nella cartella Task Scheduler:

```text
\LogCollector\LogCollector-CustomInventory
\LogCollector\LogCollector-CustomInventory-Spool
```

| Task | Eseguibile | Script |
|---|---|---|
| `LogCollector-CustomInventory` | `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` | `%ProgramW6432%\<CustomerName>\CustomInventory\Run-Inventory.ps1` |
| `LogCollector-CustomInventory-Spool` | `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` | `%ProgramW6432%\<CustomerName>\CustomInventory\Sync-Spool.ps1` |

Entrambi sono eseguiti come `NT AUTHORITY\SYSTEM`. Il primo usa la pianificazione
mercoledì/sabato alle 09:00 con ritardo casuale massimo di due ore; il secondo
parte circa cinque minuti dopo l'installazione e si ripete ogni ora.

## Percorsi temporanei durante aggiornamento e rollback

Durante l'aggiornamento possono esistere brevemente:

```text
%ProgramW6432%\<CustomerName>\CustomInventory.staging-<guid>
%ProgramW6432%\<CustomerName>\CustomInventory.retired-<guid>
%ProgramW6432%\<CustomerName>\CustomInventory.failed-<guid>
```

I task non devono mai puntare a queste directory. L'azione registrata usa sempre
il percorso stabile `...\CustomInventory`.

Lo spool può creare temporaneamente file `*.tmp` nel bucket condiviso e il file
di stato di un altro script può usare un suffisso `.<guid>.tmp`; Custom Inventory
non usa una directory `%TEMP%` per i dati raccolti.

## Detection e disinstallazione

La detection verifica:

- percorso Core stabile e versione minima;
- percorso Custom Inventory stabile;
- file `Version`;
- versione e SHA-256 di `Config.psd1`;
- presenza dei file richiesti;
- azioni, principal ed enablement dei due task.

La disinstallazione rimuove soltanto:

```text
\LogCollector\LogCollector-CustomInventory
\LogCollector\LogCollector-CustomInventory-Spool
```

Conserva intenzionalmente:

```text
%ProgramW6432%\<CustomerName>\CustomInventory
%ProgramData%\<CustomerName>\CustomInventory\Logs
%ProgramData%\LogCollectorFallback\<CustomerName>\CustomInventory\Logs
%ProgramData%\<CustomerName>\LogCollector\SharedSpool
```

La conservazione evita di cancellare diagnostica e dati accodati condivisi con
altri sender.
