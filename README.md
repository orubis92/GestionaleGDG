# GestionaleGDG

App PWA per il Comitato Giudici di Gara CSAIn (Tiro con l'arco 3D): convocazioni dei giudici alle gare, disponibilità, rimborsi, referti e verifica di fine anno secondo il Regolamento GdG rev 1.0 (2026).

Struttura del repository:

- `index.html`, `manifest.json`, `sw.js`, `icons/` — l'app (singolo file HTML, installabile come PWA)
- `supabase/schema.sql` — database, regole e permessi (da eseguire una volta su Supabase)
- `supabase/functions/sync/index.ts` — funzione di sincronizzazione con arco.swen (calendario gare e albo giudici) e riconciliazione automatica delle convocazioni
- `supabase/functions/notifica/index.ts` — funzione che invia push ed email per ogni notifica generata dal database
- `Documentazione/` — regolamenti di riferimento
- `test/` — test automatico dell'interfaccia con un finto Supabase in memoria

## Messa in opera (una volta sola)

### 1. Progetto Supabase

1. Su [supabase.com](https://supabase.com) crea un account gratuito e un nuovo progetto (regione: Frankfurt o Milano). Salva la password del database.
2. Apri **SQL Editor**, incolla per intero il contenuto di `supabase/schema.sql` ed esegui (**Run**). Al termine devono comparire le tabelle `giudici`, `gare`, `convocazioni`, ecc. in **Table Editor**. Lo script è rieseguibile senza danni.
3. In **Authentication → Providers → Email** lascia attivo Email. Se vuoi che i giudici possano accedere subito dopo la registrazione senza confermare l'email, disattiva *Confirm email*.
4. In **Authentication → URL Configuration** imposta come *Site URL* l'indirizzo dell'app (vedi punto 3), es. `https://orubis92.github.io/GestionaleGDG/`, e aggiungilo anche a *Redirect URLs*. Serve per il link "password dimenticata".
5. In **Project Settings → API** copia *Project URL* e *anon public key*.

### 2. Funzione di sincronizzazione

La sincronizzazione con arco.swen (calendario gare da `/api/eventiview/public`, albo giudici da `/api/albo`) non può girare nel browser (il portale non accetta chiamate da altri domini), quindi gira come Edge Function su Supabase. Dopo il calendario la funzione chiama `riconcilia_swen()` (in `schema.sql`) che crea/conferma/chiude le convocazioni in base al giudice registrato sul portale.

Con la Supabase CLI installata (`npm i -g supabase`), dalla cartella del repository:

```bash
supabase login
supabase link --project-ref <ref-del-progetto>     # il ref è nell'URL del progetto
supabase functions deploy sync
```

In alternativa, dal Dashboard: **Edge Functions → Deploy a new function → Via Editor**, nome `sync`, incolla il contenuto di `supabase/functions/sync/index.ts` e pubblica.

La funzione usa automaticamente le chiavi del progetto (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`): non serve configurare altro. Può essere chiamata solo da un utente con ruolo comitato.

### 2b. Notifiche push ed email (facoltativo ma consigliato)

Le notifiche **in app** (campanella, aggiornamento in tempo reale) funzionano già con lo schema, senza altro. Per riceverle anche **ad app chiusa** (push) e **via email**:

1. **Chiavi VAPID** (una volta sola). Sul tuo computer, con Node installato:
   ```bash
   npx web-push generate-vapid-keys
   ```
   Ottieni una *Public Key* e una *Private Key*. La pubblica va in `index.html`, costante `CONFIG.VAPID_PUBLIC_KEY`; la privata NON va mai nel repository.
2. **Segreti della funzione**: Supabase → Edge Functions → *Secrets* (oppure `supabase secrets set`):
   - `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT` = `mailto:` seguito dall'email del comitato
   - `APP_URL` = `https://orubis92.github.io/GestionaleGDG/`
   - `WEBHOOK_SECRET` = una stringa lunga a piacere (es. generata con `openssl rand -hex 24`): autorizza il webhook
   - per le email, uno dei due: `BREVO_API_KEY` + `EMAIL_FROM` (mittente verificato in Brevo, piano gratuito 300 email/giorno) oppure `RESEND_API_KEY` + `EMAIL_FROM` (richiede un dominio verificato).
3. **Pubblica la funzione** `notifica`: `supabase functions deploy notifica --no-verify-jwt` (o dal Dashboard, incollando `supabase/functions/notifica/index.ts` e poi, nei dettagli della funzione, disattivando *Verify JWT*). L'autorizzazione la fa la funzione stessa con il secret: con la verifica JWT del gateway attiva, il webhook viene rifiutato con "Invalid JWT" appena la chiave nel suo header Authorization viene ruotata o disattivata.
4. **Webhook**: Supabase → Database → *Webhooks* → *Create a new hook*: nome `notifica`, tabella `notifiche`, evento **Insert**, tipo **Supabase Edge Functions**, funzione `notifica`. Nella sezione *HTTP Headers* aggiungi `x-gdg-secret` con lo stesso valore di `WEBHOOK_SECRET` (l'header Authorization proposto dal Dashboard può restare). Da questo momento ogni notifica inserita dal database viene spedita.
5. **Promemoria giornalieri** (3 giorni prima di una gara confermata, il giorno prima di un corso): Supabase → Database → *Extensions* → attiva **pg_cron**, poi riesegui `schema.sql` (pianifica `invia_promemoria()` ogni giorno alle 07:00 UTC). Senza pg_cron tutto il resto funziona; mancano solo i promemoria.
6. **Realtime**: lo schema aggiunge le tabelle alla pubblicazione `supabase_realtime`. Se in Database → *Replication* le tabelle `notifiche`, `convocazioni`, `disponibilita`, `corsi`, `corsi_presenze`, `rimborsi`, `gare`, `profili` non risultano attive, attivale da lì.

Poi, nell'app: campanella → **Attiva su questo dispositivo** → **Invia una prova**. Su iPhone/iPad le push arrivano solo con l'app aggiunta alla schermata Home.

Se le push non arrivano, nell'app (account comitato) campanella → **Diagnostica**: controlla iscrizione, chiavi VAPID, webhook, secret e funzione e indica cosa sistemare. In particolare, **dopo aver cambiato chiavi**: se hai ruotato le chiavi API di Supabase (o sei passato alle nuove chiavi `sb_publishable_`/`sb_secret_` disattivando quelle legacy) ripubblica `notifica` e `sync` e aggiorna `CONFIG.SUPABASE_ANON_KEY` in `index.html`; se hai rigenerato le chiavi VAPID aggiorna sia i secret della funzione sia `CONFIG.VAPID_PUBLIC_KEY`, e ogni dispositivo deve disattivare e riattivare le push (le iscrizioni fatte con la vecchia chiave non sono più valide: la funzione riceve 403 dal servizio push); se hai cambiato `WEBHOOK_SECRET` aggiorna l'header `x-gdg-secret` del webhook.

### 3. Pubblicazione dell'app (GitHub Pages)

1. Apri `index.html` e compila le due costanti in cima allo script:
   ```js
   const CONFIG = {
     SUPABASE_URL: 'https://xxxxx.supabase.co',
     SUPABASE_ANON_KEY: 'eyJ...'
   };
   ```
   (La chiave *anon* è pubblica per definizione: la sicurezza è garantita dalle policy nel database.) Se le lasci vuote, l'app le chiede al primo avvio e le salva sul dispositivo.
2. Fai commit e push su GitHub.
3. Nel repository: **Settings → Pages → Build and deployment**: *Deploy from a branch*, branch `main`, cartella `/ (root)`. Dopo un minuto l'app è raggiungibile su `https://orubis92.github.io/GestionaleGDG/`.

Ogni push successivo aggiorna l'app; il service worker è *network-first*, quindi gli utenti ricevono la nuova versione alla prima apertura con rete. Ricorda di aggiornare `APP_VER` in `index.html` e `CACHE` in `sw.js` a ogni versione.

### 4. Primo accesso

1. Apri l'app, **Registrati** con la tua email e conferma (se richiesto).
2. Nell'SQL Editor di Supabase esegui, con la tua email:
   ```sql
   update profili set ruolo = 'comitato' where email = 'tua@email.it';
   ```
3. Rientra nell'app: hai le schede del comitato e l'icona ⚙ delle impostazioni.
4. Da **⚙ Impostazioni**: imposta i **parametri** dell'anno sportivo (tariffa km, gettoni), poi lancia **Sincronizza → Albo giudici** e **Calendario gare**. Gli aggiornamenti tecnici si creano da **Gare → Corsi e aggiornamenti**.
5. Nella scheda **Giudici** completa qualifica, contatti e scadenze dei giudici importati (l'albo fornisce solo nome, cognome e provincia) e collega il tuo account al tuo profilo giudice (⚙ → Account e ruoli).
6. Imposta il **codice di registrazione** (⚙ → Codice di registrazione) e comunicalo ai giudici: senza codice la registrazione viene rifiutata. I giudici si registrano dall'app: l'account nasce **ospite** (nessun accesso). Da ⚙ → Account e ruoli premi **Attiva**, scegli il ruolo e il profilo giudice (suggerito se l'email coincide). Per revocare un accesso riporta l'account a Ospite.

## Aggiornare l'app

Modifica `index.html`, aggiorna `APP_VER` e la voce "Novità" nella guida, aggiorna `CACHE` in `sw.js`, commit e push.

Per modifiche al database aggiungi le istruzioni in fondo a `supabase/schema.sql` (lo script è idempotente) ed eseguilo di nuovo nell'SQL Editor. **Dopo ogni aggiornamento dello schema va anche ripubblicata la funzione `sync`** se è cambiata (`supabase functions deploy sync` o incolla di nuovo il file dal Dashboard).

Storico aggiornamenti dello schema: v1.7 (funzione `diagnostica_notifiche()` per il comitato; il vincolo unique su `convocazioni (gara_id, giudice_id)` diventa un indice parziale sulle sole convocazioni attive: un giudice può essere riconvocato dopo un annullamento o un rifiuto); v1.6 (viste con `security_invoker`, vista `giudici_pubblici`, lettura di `giudici` limitata a interessato e comitato, tabella `impostazioni` con codice di registrazione verificato in `handle_new_user`, `verifica_codice_registrazione`, privilegi delle funzioni revocati a PUBLIC/anon); v1.5 (tabelle `notifiche`, `push_iscrizioni`, `notifiche_preferenze`; trigger che generano le notifiche su convocazioni, presenze ai corsi, rimborsi, disponibilità, nuovi account; `invia_promemoria()` con pg_cron; tabelle aggiunte a `supabase_realtime`); v1.4 (tabelle `corsi` e `corsi_presenze`, funzione `invita_tutti`, `riconcilia_swen` prudente, `is_comitato`/`is_attivo` che escludono il ruolo anon, revoca dell'esecuzione delle funzioni ad anon, colonna `gare.swen_classifica`, scrittura su `aggiornamenti` solo comitato); v1.2 (albo arco.swen, colonne `swen_id`/`tessera_numero`/`tessera_tipo` su `giudici`, funzione `riconcilia_swen`); v1.3 (ruolo `ospite` predefinito per i nuovi account, funzione `is_attivo()` nelle policy, nessun collegamento automatico per email).

## Test locale dell'interfaccia

```bash
cd test && npm install && node run.js
```
Avvia l'app con un finto Supabase in memoria, percorre tutte le viste come comitato e come giudice e salva le schermate in `test/shots/`. Serve a intercettare errori JavaScript prima di pubblicare, non sostituisce la prova sul progetto reale.
