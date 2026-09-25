# Percorsi degli altri script e degli strumenti di pubblicazione

Questo documento copre gli script che non fanno parte del package Custom Inventory:
remediation, utility standalone, test operativi e generatori di artefatti. I
percorsi installati da Core e Inventory sono documentati separatamente in
[paths-core-client.md](paths-core-client.md) e
[paths-custom-inventory.md](paths-custom-inventory.md).

## Application Logging Remediation

Sorgenti nella repository:

```text
scripts\Remediations\ApplicationLogging\
    Detect.ps1
    Remediate.ps1
    README.md
```

Stato persistente previsto sul dispositivo:

```text
%ProgramData%\<CustomerName>\LogCollector\State\ApplicationLoggingRemediation.json
```

Scrittura atomica temporanea:

```text
%ProgramData%\<CustomerName>\LogCollector\State\
    ApplicationLoggingRemediation.json.<guid>.tmp
```

Spool usato dalla remediation:

```text
%ProgramData%\<CustomerName>\LogCollector\SharedSpool\<EndpointHash>
```

La remediation non installa file in `Program Files`, non registra task e non
crea un log dedicato. Detection e remediation sono conservate da Intune nel
proprio contenuto gestito; quel percorso è controllato da Intune Management
Extension e non fa parte del contratto LogCollector.

### Nota di compatibilità

La versione 1.1.0 presente nella repository cerca ancora il modulo in una
sottodirectory versionata:

```text
%ProgramW6432%\WindowsPowerShell\Modules\LogCollector.Client\<versione>\
```

Core 1.11.1 installa invece il manifest direttamente nel percorso stabile:

```text
%ProgramW6432%\WindowsPowerShell\Modules\LogCollector.Client\LogCollector.Client.psd1
```

La remediation 1.1.0 non deve quindi essere distribuita con Core 1.11.1 finché
il lookup non viene aggiornato al percorso stabile. Questa differenza riguarda
solo Application Logging Remediation; Custom Inventory 1.9.1 usa già il percorso
corretto.

## Utility standalone di inventory

### `scripts\Invoke-CustomInventory.ps1`

Questa utility è un entry point di sviluppo/compatibilità e non è il package
Custom Inventory 1.9.1. Importa i moduli dalla checkout della repository:

```text
<RepositoryRoot>\src\Client\
    DeviceIdentity.psm1
    InventorySpool.psm1
    InventoryClient.psm1
```

Il suo spool predefinito è legacy:

```text
C:\ProgramData\LogCollector\Spool
```

La URL Intake è passata esplicitamente a riga di comando. Per nuovi deployment
gestiti usare Core più Custom Inventory, non questa utility.

### `scripts\Register-InventoryScheduledTask.ps1`

Per impostazione predefinita registra:

```text
\LogCollector\LogCollector-Inventory
```

L'azione punta al percorso assoluto risolto di:

```text
<RepositoryRoot>\scripts\Invoke-CustomInventory.ps1
```

e passa lo spool legacy:

```text
C:\ProgramData\LogCollector\Spool
```

Questo task non coincide con:

```text
\LogCollector\LogCollector-CustomInventory
\LogCollector\LogCollector-CustomInventory-Spool
```

Non usare contemporaneamente l'utility standalone e il package Custom Inventory
sullo stesso dispositivo, perché raccoglierebbero dati equivalenti con contratti
e percorsi differenti.

## Script di test operativo

Gli script sotto `tests\Deployment` sono eseguiti dalla repository o dalla
pipeline e non installano componenti permanenti:

```text
tests\Deployment\Test-EndToEndSubmission.ps1
tests\Deployment\Test-ApplicationLoggingLoad.ps1
```

Usano il modulo o i sorgenti indicati dai propri parametri. Il test end-to-end
dichiara esplicitamente di non creare task, spool o stato locale; il load test
usa i percorsi forniti al comando e non definisce un percorso client permanente.

## Output dei generatori

Tutti i percorsi seguenti sono relativi alla root della repository, salvo
override esplicito del parametro `-OutputRoot` o `-OutputDirectory`.

| Script | Output predefinito |
|---|---|
| `scripts\New-IntunePackage.ps1` dalla repository | `out\Intune\Core\<CoreVersion>` |
| `2-Intune\New-IntunePackage.ps1` nel deliverable cliente | `2-Intune\Output\<CoreVersion>` |
| `scripts\Publish-InventoryPackage.ps1` | `out\Inventory\<InventoryVersion>` |
| `scripts\Publish-IntuneWin32Package.ps1` | `out\IntuneWin32\<InventoryVersion>` |
| `scripts\Publish-ClientModule.ps1` | `out\Client\<guid>` |
| `scripts\Publish-DeploymentPackage.ps1` | `out\Deploy\<BackendVersion>` |
| `scripts\Publish-CustomerDeliverable.ps1` | `out\Customer\<BackendVersion>` |
| `scripts\Publish-Function.ps1` | `out\<Component>-<guid>` |

### Core Intune

```text
out\Intune\Core\<CoreVersion>\
    Source\
    Package\
        Install.intunewin
    Detect.ps1
```

### Custom Inventory Intune

```text
out\IntuneWin32\<InventoryVersion>\
    Source\
        <InventoryVersion>\
    Output\
        Install.intunewin
    Detect.ps1
    Intune-Deployment.md
```

### Modulo Client ZIP

```text
out\Client\<guid>\
    package\
        LogCollector.Client\<versione>\
    LogCollector.Client-<versione>.zip
```

Questo è un artefatto di distribuzione separato. Non rappresenta il layout
machine-wide installato dal Core 1.11.1, che resta non versionato.

### Package Azure

```text
out\Deploy\<BackendVersion>\
    Deploy-LogCollector.ps1
    MANIFEST.json
    README.md
    Functions\
        Frontend.zip
        Worker.zip
    infra\
    Logs\
        Deploy-LogCollector-<yyyyMMdd-HHmmss>.log
```

Il log di deployment può essere spostato con `-LogPath`. Durante la configurazione
delle IP restriction viene creato e poi rimosso:

```text
%TEMP%\LogCollector-ip-restrictions-<guid>.json
```

### Deliverable cliente

```text
out\Customer\<BackendVersion>\
    1-Azure\
    2-Intune\
        CoreSource\
        New-IntunePackage.ps1
        Intune-Deployment.md
        Tools\
    MANIFEST.json
    README.md
```

La directory intermedia `azure-staging` viene rimossa dal builder dopo aver
copiato il package definitivo. La directory seguente non è inclusa nel deliverable
iniziale: viene creata solo quando il cliente esegue `New-IntunePackage.ps1`:

```text
out\Customer\<BackendVersion>\2-Intune\Output\<CoreVersion>\
```

## Snapshot pubblico

`scripts\Publish-PublicSnapshot.ps1` usa una directory temporanea:

```text
%TEMP%\LogCollector-public-<guid>\
    snapshot\
    snapshot.zip
    public\
```

Viene eliminata al termine salvo uso esplicito di `-KeepStaging`. Non è un
percorso di installazione o di raccolta dati.
