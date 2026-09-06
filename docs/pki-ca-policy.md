# PKI: vincoli distinti per Root CA e SubCA

Disponibile nel modulo condiviso e nel pacchetto inventory **1.1.1**, e nell'Intake
**1.1.1**. La configurazione e universale: nessun nome CA, thumbprint o tenant cliente
e incorporato nel codice. Liste vuote conservano il comportamento precedente.

## Configurazione simmetrica

| Config.psd1 / parametro PowerShell | Variabile di ambiente Intake | Parametro Bicep |
|---|---|---|
| PkiRootCaThumbprints | ClientCert__PkiRootCaThumbprints | pkiRootCaThumbprints |
| PkiRootCaSubjects | ClientCert__PkiRootCaSubjects | pkiRootCaSubjects |
| PkiIntermediateCaThumbprints | ClientCert__PkiIntermediateCaThumbprints | pkiIntermediateCaThumbprints |
| PkiIntermediateCaSubjects | ClientCert__PkiIntermediateCaSubjects | pkiIntermediateCaSubjects |

In PowerShell usare array di stringhe, `@()` per nessun vincolo. Nell'Intake usare
stringhe: i thumbprint possono essere separati da virgola, punto e virgola o pipe;
i Subject DN sono separati **solo da pipe**, perche le virgole fanno parte del DN.
Una stringa Intake assente/vuota disabilita quel vincolo. Elementi vuoti in una lista
non vuota o thumbprint malformati sono errori, non vengono ignorati.

I nomi sono i **Subject DN completi**, confrontati senza distinzione tra maiuscole
e minuscole. Non sono Friendly Name, nomi dei file `.cer`, soli Common Name o wildcard.
I thumbprint sono quelli SHA1 esposti dalla proprieta Windows `Thumbprint`: **40
cifre esadecimali**. Spazi e due punti sono normalizzati; impronte SHA256 non sono
intercambiabili con questo campo.

Un Subject DN non identifica univocamente un certificato: per un vincolo preciso
usare anche il thumbprint e gli ancoraggi pubblici previsti. Durante un rinnovo CA,
ammettere le impronte vecchie e nuove per il periodo di transizione su entrambi i lati,
poi rimuovere quelle obsolete; non disabilitare i controlli per aggirare un mismatch.

## Regole di autorizzazione

I vincoli PKI si applicano a una catena validata, non al testo Issuer dichiarato
dal certificato del dispositivo:

1. La Root CA e il certificato CA terminale della catena.
2. Una SubCA e un certificato CA intermedio: non il dispositivo, non la Root CA.
3. Ogni ruolo configurato deve essere soddisfatto: Root **AND** SubCA.
4. Dentro una singola lista basta un valore consentito.
5. Se per un ruolo sono configurati sia nomi sia thumbprint, **lo stesso certificato
   CA** deve soddisfare entrambi. Non basta trovare il nome su una CA e l'impronta su un'altra.
6. Se si configurano SubCA, una catena direttamente firmata dalla Root non soddisfa
   il vincolo. Con piu livelli intermedi e sufficiente un intermedio consentito:
   non e una descrizione ordinata dell'intera gerarchia.

Il certificato che soddisfa il ruolo deve avere Basic Constraints CA=true.
Questi filtri non sostituiscono firme della catena, validita temporale, EKU,
binding del dispositivo o controlli di revoca dell'Intake.

La selezione client di un candidato Intune usa l'OID associato all'Entra device ID
atteso, anche quando viene indicato un thumbprint o un Subject esplicito. Questo e
solo un criterio di selezione: non prova che il certificato provenga da Intune.
L'Intake deve comunque validare catena Intune, issuer, binding e autorizzazione Entra;
un certificato PKI con un OID arbitrario non acquisisce fiducia per questo motivo.

I vecchi TrustedCaSubjects/TrustedCaThumbprints dell'Intake restano supportati e,
se configurati, aggiungono i loro vincoli generici. Non servono per usare i nuovi
filtri e non diventano automaticamente vincoli separati Root/SubCA.

## Lato client: selezione, non autorita finale

Nel pacchetto generato modificare `Config.psd1`; il runtime inoltra la stessa
configurazione sia a Send-LogCollectorData sia a Sync-LogCollectorSpool:

```powershell
PkiRootCaThumbprints = @()
PkiRootCaSubjects = @()
PkiIntermediateCaThumbprints = @()
PkiIntermediateCaSubjects = @()
```

Per ricavare i valori dai certificati **pubblici** della propria PKI:

```powershell
$root = [Security.Cryptography.X509Certificates.X509Certificate2]::new('C:\PKI\RootCA.cer')
$sub = [Security.Cryptography.X509Certificates.X509Certificate2]::new('C:\PKI\IssuingCA.cer')
try {
    .\scripts\Publish-InventoryPackage.ps1 `
        -FrontendUrl 'https://your-intake.azurewebsites.net/api/inventory' `
        -Environment 'Lab' `
        -PkiRootCaThumbprints @($root.Thumbprint) -PkiRootCaSubjects @($root.Subject) `
        -PkiIntermediateCaThumbprints @($sub.Thumbprint) -PkiIntermediateCaSubjects @($sub.Subject)
}
finally {
    $root.Dispose()
    $sub.Dispose()
}
```

Il builder non importa certificati negli store Windows e non include chiavi private.
Provisionare prima le CA sul dispositivo con i normali meccanismi PKI/Intune/GPO:
Root fidate in `LocalMachine\Root`, intermedi in `LocalMachine\CA`.
La costruzione della catena puo recuperare intermedi via AIA con timeout limitato.
Il controllo locale di selezione non esegue la revoca; l'Intake mantiene i propri
controlli CRL/OCSP. La verifica locale non rende attendibile il contenuto del client.

CertificateThumbprint continua a indicare il **certificato del dispositivo**.
CertificateIssuerLike continua a filtrare il suo emittente diretto.
Selezionare un leaf esplicito non elimina i vincoli PKI applicabili.
Un candidato PKI escluso non viene usato perche e il primo in elenco.
Se non rimane un certificato utilizzabile, il sender conserva il dato nello spool
come AuthFailure; una configurazione malformata invece genera un errore esplicito.

## Lato Intake: fiducia e vincoli sono distinti

Configurare anche i certificati pubblici Base64 DER:

| Impostazione esistente | Ruolo |
|---|---|
| ClientCert__TrustedRootCertificates | Root fidate, ancoraggi crittografici |
| ClientCert__TrustedIntermediateCertificates | Intermedi disponibili per costruire la catena, non obbligatori di per se |

I nuovi Pki* sono **vincoli**, non nuovi ancoraggi di fiducia.
Per esempio, avere l'impronta di una Root non elimina la necessita di una catena
attendibile. Per richiedere una determinata SubCA occorre configurare il relativo
vincolo, non soltanto aggiungere il suo certificato agli intermedi.

I parametri Bicep consentono di mantenere la configurazione dichiarativa coerente
con le variabili Intake. Non distribuire nomi o thumbprint d'esempio come se fossero
CA reali. Una configurazione PKI malformata fallisce esplicitamente, senza usare
Intune per nascondere l'errore di configurazione.

## Intune e compatibilita

I vincoli Pki* non si applicano al profilo Intune. Con configurazione valida, il
fallback Intune rimane indipendente e richiede i controlli gia previsti dal server:
catena Intune fidata, binding, firma e dispositivo Entra abilitato.
Non interpretare questi filtri come una modalita PKIOnly. Per disabilitare il
fallback lato Intake esiste ClientCert__AllowIntuneEnrollmentCertificateFallback.

Il pacchetto precedente non viene sovrascritto: la nuova cartella e
`out\Inventory\1.1.1`. L'installer aggiorna i propri task verso la nuova versione,
conservando lo spool indipendente e il ritardo casuale di due ore.
Scegliere manualmente le CA della propria PKI: nel profilo laboratorio distribuito
i nuovi filtri sono vuoti e non vengono inventati valori sostitutivi.
