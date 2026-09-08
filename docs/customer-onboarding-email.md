# LogCollector — requisiti per il deployment su Azure

Bozza di mail da inviare al cliente prima della consegna del pacchetto.
Sostituire i segnaposto `<...>` prima dell'invio.

---

**Oggetto:** LogCollector — prerequisiti tecnici e autorizzazioni per il deployment su Azure

Buongiorno <Nome>,

in vista dell'installazione di **LogCollector** vi riepilogo di seguito tutto ciò che è
necessario predisporre lato vostro. Il pacchetto che vi consegneremo è già compilato e
autoconsistente: **non è richiesto alcun ambiente di sviluppo**, né Visual Studio, né .NET SDK,
né accesso al codice sorgente.

L'attività si svolge in due fasi: il deployment dell'infrastruttura su Azure e la
pubblicazione dell'agent sui client tramite Intune.

---

## 1. Software richiesto sulla postazione che esegue il deployment

| Componente | Note |
| --- | --- |
| **Azure CLI** (`az`), versione 2.60 o superiore | https://aka.ms/installazurecli |
| **Windows PowerShell 5.1** (già presente su Windows) oppure PowerShell 7 | — |
| **IntuneWinAppUtil.exe** (Microsoft Win32 Content Prep Tool) | Solo per la fase 2. https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool |

Non è necessario installare Bicep separatamente: viene gestito automaticamente dall'Azure CLI.

La postazione deve poter raggiungere `login.microsoftonline.com` e `management.azure.com`
in HTTPS.

---

## 2. Informazioni che ci servono da voi

Per poter preparare e validare il pacchetto vi chiediamo di comunicarci:

1. **ID della sottoscrizione** Azure di destinazione.
2. **Nome del resource group** da utilizzare (esistente o da creare).
3. **Region** di destinazione (es. `italynorth`, `westeurope`).
4. **Sigla identificativa** di massimo 8 caratteri alfanumerici (es. `<SIGLA>`).
   Viene anteposta al nome di tutte le risorse create.
   *Perché serve:* i nomi di Storage Account, Service Bus e Function App devono essere
   **univoci a livello mondiale** su Azure. La sigla evita collisioni con risorse già
   esistenti. Va decisa **prima del primo deployment**: modificarla successivamente comporta
   la creazione di nuove risorse, non la migrazione di quelle esistenti.
5. Eventuali **vincoli di naming o tagging** aziendali da rispettare.

---

## 3. Autorizzazioni Azure necessarie

L'utenza che esegue il deployment deve disporre, **sul resource group di destinazione**, di:

| Ruolo | Motivo |
| --- | --- |
| **Contributor** | Creazione delle risorse (storage, Service Bus, Function App, workspace, ecc.) |
| **User Access Administrator** *(oppure Role Based Access Control Administrator)* | Il template crea **10 role assignment** per assegnare i permessi alle managed identity |

> In alternativa è sufficiente il ruolo **Owner** sul resource group, che include entrambi.

**Nota importante sul secondo ruolo:** la soluzione non utilizza chiavi di accesso, password o
connection string. Ogni componente si autentica tramite **managed identity** con permessi
assegnati puntualmente (principio del privilegio minimo). Per creare tali assegnazioni è
necessario un ruolo abilitato alla gestione RBAC: senza di esso il deployment si interrompe
con errore `AuthorizationFailed` sulla creazione dei role assignment.

I permessi possono essere limitati al **solo resource group di destinazione**: non è richiesto
alcun ruolo a livello di sottoscrizione o di tenant.

Se il resource group deve essere **creato dallo script**, è invece necessario il ruolo
**Contributor a livello di sottoscrizione** (oppure createlo voi in anticipo e assegnateci i
permessi solo su di esso — è l'opzione che consigliamo).

### Resource provider da registrare

Se non già registrati nella sottoscrizione, servono i seguenti provider. La registrazione
richiede il ruolo **Contributor sulla sottoscrizione** ed è un'operazione una tantum:

```
Microsoft.Web
Microsoft.Storage
Microsoft.ServiceBus
Microsoft.OperationalInsights
Microsoft.Insights
Microsoft.ManagedIdentity
Microsoft.Authorization
```

Verifica e registrazione:

```powershell
az provider show --namespace Microsoft.ServiceBus --query registrationState -o tsv
az provider register --namespace Microsoft.ServiceBus
```

---

## 4. Risorse che verranno create

Tutte all'interno del solo resource group indicato:

| Risorsa | Quantità | Note |
| --- | --- | --- |
| Storage Account | 1 | Accesso solo tramite identità, chiavi condivise disabilitate |
| Service Bus (namespace + coda) | 1 | Disaccoppia ricezione ed elaborazione |
| Function App | 2 | Ricezione dati (intake) ed elaborazione (worker) |
| App Service Plan | 2 | — |
| Log Analytics Workspace | 1 | Destinazione finale dei dati |
| Application Insights | 1 | Diagnostica della soluzione |
| Data Collection Endpoint / Rule | 1 + 1 | Ingestion verso Log Analytics |
| Managed Identity | 2 | Una per Function App |
| Role assignment | 10 | Permessi minimi per le identity sopra |

**Stima di spesa indicativa:** <inserire stima> €/mese, prevalentemente legata alla ritenzione
dei dati in Log Analytics.

---

## 5. Requisiti per la parte client (Intune)

I dispositivi si autenticano verso il servizio in **mutual TLS**, utilizzando il
**certificato di dispositivo rilasciato da Intune** già presente sulle macchine gestite.

Ne consegue che:

* **non viene distribuito alcun segreto, chiave o password sugli endpoint**;
* non è necessario predisporre una PKI dedicata;
* i dispositivi devono essere **gestiti da Intune** (Entra ID joined o Hybrid joined) e
  possedere un certificato valido emesso da *Microsoft Intune MDM Device CA* o
  *Microsoft Intune Device Management Device CA*.

Requisiti dei client: **Windows 10 1809 o superiore / Windows 11, 64 bit**. L'agent viene
eseguito come SYSTEM tramite scheduled task.

Lato Intune serve un'utenza con i permessi per **creare e assegnare una app Win32**
(ruolo *Application Manager* o *Intune Administrator*).

I dispositivi devono poter raggiungere in **HTTPS (443)** l'endpoint della Function App:
`https://<SIGLA>-logcollector-intake.azurewebsites.net`. Se è presente un proxy con
ispezione TLS, l'endpoint va **inserito in esclusione**: l'ispezione interrompe il mutual TLS
e impedisce l'autenticazione dei dispositivi.

---

## 6. Verifica preliminare (consigliata)

Il pacchetto include una modalità di simulazione che **non applica alcuna modifica**.
Vi suggeriamo di eseguirla per validare in anticipo permessi e prerequisiti:

```powershell
az login
cd 1-Azure
.\Deploy-LogCollector.ps1 `
  -SubscriptionId <id-sottoscrizione> `
  -ResourceGroup  <resource-group> `
  -Location       italynorth `
  -CustomerPrefix <SIGLA> `
  -WhatIf
```

Se il comando termina senza errori, i prerequisiti sono soddisfatti. In caso contrario
inviateci l'output: dal messaggio è immediato capire quale permesso o provider manchi.

---

## 7. Un'avvertenza su eventuali policy aziendali

Se nel vostro tenant sono attive **Azure Policy** che impongono la disabilitazione
dell'accesso pubblico agli Storage Account, il deployment dell'applicazione può fallire con
un errore `403` di tipo `InaccessibleStorageException`.

Il motivo: il servizio di deployment di Azure carica il pacchetto applicativo sullo Storage
Account attraverso l'endpoint pubblico. L'accesso ai **dati** resta comunque protetto in ogni
caso, poiché le chiavi condivise sono disabilitate e ogni accesso richiede un'identità
Entra ID esplicitamente autorizzata.

Se la policy è presente, è sufficiente predisporre un'**esenzione per il solo Storage Account**
della soluzione. La procedura completa è documentata nel `README.md` incluso nel pacchetto.

---

Restiamo a disposizione per una call di allineamento prima dell'avvio, così da verificare
insieme permessi e prerequisiti ed evitare interruzioni durante l'installazione.

Cordiali saluti,
<Firma>
