-- =====================================================================
--  GestionaleGDG — schema Supabase (Postgres)  v1.7
--  Comitato Giudici di Gara CSAIn — Tiro con l'arco 3D
--
--  Da incollare per intero nell'SQL Editor di Supabase ed eseguire.
--  Idempotente: può essere rieseguito (usa IF NOT EXISTS / OR REPLACE).
--  Riferimenti normativi: Regolamento GdG rev 1.0 2026 (art. citati nei commenti).
-- =====================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------
-- 1. TABELLE
-- ---------------------------------------------------------------------

-- Giudici (anagrafica; l'albo nazionale fornisce solo ID, nome, cognome, provincia, sesso)
create table if not exists giudici (
  id                      uuid primary key default gen_random_uuid(),
  albo_id                 text unique,                        -- ID nell'Albo Nazionale CSAIN
  cognome                 text not null,
  nome                    text not null,
  sesso                   text check (sesso in ('M','F')),
  email                   text,
  telefono                text,
  indirizzo               text,
  cap                     text,
  comune                  text,
  provincia               text,                               -- sigla (BG, CR, ...)
  regione                 text,
  macroarea               text,                               -- art. 10 quater
  societa                 text,                               -- società di appartenenza (per incompatibilità art. 4)
  societa_codice          text,
  qualifica               text not null default 'regionale'
                          check (qualifica in ('regionale','nazionale','emerito')),   -- art. 7
  in_affiancamento        boolean not null default false,     -- art. 2: almeno 2 gare affiancato
  affiancamenti_richiesti int not null default 2,
  data_nascita            date,                               -- art. 20: 18–75 anni
  data_inizio_attivita    date,
  scadenza_tessera        date,                               -- tessera RCT, art. 3 / 6
  scadenza_certificato    date,                               -- certificato medico non agonistico, art. 13
  attivo                  boolean not null default true,
  origine                 text not null default 'manuale' check (origine in ('albo','manuale')),
  presente_in_albo        boolean,                            -- esito ultima sync albo
  ultima_sync_albo        timestamptz,
  note                    text,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);
-- v1.2/v1.4: colonne aggiunte in seguito (devono esistere prima delle viste)
alter table giudici add column if not exists swen_id        int unique;   -- id nell'albo di arco.swen (/api/albo)
alter table giudici add column if not exists tessera_numero text;         -- NumeroTesseraTecnico
alter table giudici add column if not exists tessera_tipo   text;         -- TipoTesseraTecnico (es. QUADRI COPERTURA RCT)
create index if not exists giudici_cognome_idx on giudici (cognome, nome);
create index if not exists giudici_email_idx on giudici (lower(email));

-- Gare (dal calendario arco.swen o manuali)
create table if not exists gare (
  id                      uuid primary key default gen_random_uuid(),
  swen_id                 int unique,                         -- id evento su arco.swen
  titolo                  text not null,
  descrizione             text,
  data_inizio             date not null,
  data_fine               date,
  anno_sportivo           text,                               -- es. "2025/2026"
  societa_organizzatrice  text,
  societa_codice          text,
  regione                 text,
  provincia               text,
  comune                  text,
  indirizzo               text,
  cap                     text,
  coordinate_gps          text,
  email_riferimento       text,
  tipo_codice             text,                               -- es. 44_FUSION, 60_TRACK, 40_ROUND ...
  tipo_descrizione        text,
  classificazione         text,                               -- Provinciale/Regionale/Nazionale/Internazionale/Europeo/...
  indoor                  boolean not null default false,
  numero_percorsi         int not null default 1,             -- Reg. Sportivo par. VI a: 2 percorsi → 2 giudici
  fabbisogno_giudici      int not null default 1,
  stato                   text not null default 'programmata'
                          check (stato in ('programmata','svolta','annullata')),
  origine                 text not null default 'manuale' check (origine in ('swen','manuale')),
  giudice_swen            text,                               -- nome giudice registrato su arco.swen
  swen_stato              text,                               -- Inserito/Aperto/Chiuso
  swen_classifica         boolean,                            -- isClassificaCalcolata sul portale (gara effettivamente svolta)
  swen_partecipanti       int,
  swen_updated_at         timestamptz,
  ultima_sync             timestamptz,
  note                    text,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);
alter table gare    add column if not exists swen_classifica boolean;      -- v1.4
create index if not exists gare_data_idx on gare (data_inizio);
create index if not exists gare_anno_idx on gare (anno_sportivo);

-- Profili: collega l'utente Supabase Auth a un giudice e definisce il ruolo applicativo
create table if not exists profili (
  id          uuid primary key references auth.users (id) on delete cascade,
  email       text,
  ruolo       text not null default 'ospite' check (ruolo in ('comitato','giudice','ospite')),
  giudice_id  uuid references giudici (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
-- v1.3: gli account nuovi nascono "ospite" (nessun accesso ai dati) finché il comitato non li attiva
alter table profili drop constraint if exists profili_ruolo_check;
alter table profili add constraint profili_ruolo_check check (ruolo in ('comitato','giudice','ospite'));
alter table profili alter column ruolo set default 'ospite';

-- Disponibilità dichiarate dai giudici
create table if not exists disponibilita (
  id          uuid primary key default gen_random_uuid(),
  gara_id     uuid not null references gare (id) on delete cascade,
  giudice_id  uuid not null references giudici (id) on delete cascade,
  stato       text not null check (stato in ('disponibile','non_disponibile')),
  note        text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (gara_id, giudice_id)
);

-- Convocazioni
create table if not exists convocazioni (
  id              uuid primary key default gen_random_uuid(),
  gara_id         uuid not null references gare (id) on delete cascade,
  giudice_id      uuid not null references giudici (id) on delete cascade,
  ruolo           text not null default 'giudice'
                  check (ruolo in ('giudice','coordinatore','affiancamento')),   -- art. 7 ter
  stato           text not null default 'proposta'
                  check (stato in ('proposta','accettata','rifiutata','confermata','svolta','assente','annullata')),
  motivo_rifiuto  text,                                       -- art. 11.2: obbligatorio se rifiutata
  deroga          boolean not null default false,             -- regionale su gara nazionale, autorizzata dal comitato
  note            text,
  created_by      uuid references auth.users (id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (stato <> 'rifiutata' or coalesce(length(trim(motivo_rifiuto)),0) > 0)
);
create index if not exists convocazioni_giudice_idx on convocazioni (giudice_id);
create index if not exists convocazioni_gara_idx on convocazioni (gara_id);
-- v1.7: un giudice può avere una sola convocazione "viva" per gara; le righe annullate/rifiutate
-- restano nello storico e non impediscono una nuova convocazione (il vincolo unique di v1.0 lo impediva)
alter table convocazioni drop constraint if exists convocazioni_gara_id_giudice_id_key;
create unique index if not exists convocazioni_attiva_uniq
  on convocazioni (gara_id, giudice_id) where stato not in ('annullata','rifiutata');

-- Storico cambi di stato delle convocazioni (popolato da trigger)
create table if not exists convocazioni_storico (
  id               uuid primary key default gen_random_uuid(),
  convocazione_id  uuid not null references convocazioni (id) on delete cascade,
  stato_da         text,
  stato_a          text not null,
  autore           uuid,
  note             text,
  created_at       timestamptz not null default now()
);

-- Aggiornamenti tecnici seguiti (art. 10 bis: almeno uno ogni 12 mesi)
create table if not exists aggiornamenti (
  id          uuid primary key default gen_random_uuid(),
  giudice_id  uuid not null references giudici (id) on delete cascade,
  data        date not null,
  descrizione text not null,
  ore         numeric(5,1),
  note        text,
  created_at  timestamptz not null default now()
);

-- Corsi, aggiornamenti tecnici e riunioni organizzati dal comitato (v1.4) — art. 10 bis
create table if not exists corsi (
  id           uuid primary key default gen_random_uuid(),
  titolo       text not null,
  tipo         text not null default 'aggiornamento' check (tipo in ('aggiornamento','corso','riunione','altro')),
  data         date not null,
  data_fine    date,
  ore          numeric(5,1),
  luogo        text,
  descrizione  text,
  obbligatorio boolean not null default false,
  stato        text not null default 'programmato' check (stato in ('programmato','svolto','annullato')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
-- Inviti e presenze: il comitato invita (tutti i giudici attivi), il giudice dichiara se partecipa, il comitato segna la presenza
create table if not exists corsi_presenze (
  id          uuid primary key default gen_random_uuid(),
  corso_id    uuid not null references corsi (id) on delete cascade,
  giudice_id  uuid not null references giudici (id) on delete cascade,
  stato       text not null default 'invitato'
              check (stato in ('invitato','partecipa','non_partecipa','presente','assente','giustificato')),
  note        text,
  updated_at  timestamptz not null default now(),
  unique (corso_id, giudice_id)
);
alter table corsi          enable row level security;
alter table corsi_presenze enable row level security;

-- Rimborsi (uno per convocazione) — art. 16
create table if not exists rimborsi (
  id                 uuid primary key default gen_random_uuid(),
  convocazione_id    uuid not null unique references convocazioni (id) on delete cascade,
  modalita           text not null default 'km_spese'
                     check (modalita in ('km_spese','gettone_km','manuale')),
  km                 numeric(8,1) not null default 0,         -- andata/ritorno
  tariffa_km         numeric(6,3) not null default 0,
  gettone            numeric(8,2) not null default 0,
  spese              jsonb not null default '[]'::jsonb,      -- [{"descrizione":"pedaggio","importo":12.5}]
  importo_manuale    numeric(8,2),
  totale             numeric(10,2) not null default 0,        -- calcolato da trigger
  stato              text not null default 'da_compilare'
                     check (stato in ('da_compilare','compilato','approvato','liquidato')),
  data_liquidazione  date,
  note               text,
  updated_at         timestamptz not null default now()
);

-- Referti caricati (file su Storage, bucket "referti") — art. 14
create table if not exists referti (
  id               uuid primary key default gen_random_uuid(),
  convocazione_id  uuid not null references convocazioni (id) on delete cascade,
  storage_path     text not null,
  nome_file        text not null,
  dimensione       int,
  caricato_da      uuid references auth.users (id),
  created_at       timestamptz not null default now()
);

-- Parametri per anno sportivo (art. 16: misura stabilita annualmente)
create table if not exists parametri (
  anno_sportivo         text primary key,                     -- es. "2026/2027"
  tariffa_km            numeric(6,3) not null default 0,
  gettone_regionale     numeric(8,2) not null default 0,      -- gettone per gara regionale/provinciale
  gettone_nazionale     numeric(8,2) not null default 0,      -- gettone per gara nazionale/internazionale
  gettone_coordinatore  numeric(8,2) not null default 0,
  modalita_default      text not null default 'km_spese'
                        check (modalita_default in ('km_spese','gettone_km','manuale')),
  min_servizi_12m       int not null default 1,               -- art. 10 bis
  min_aggiornamenti_12m int not null default 1,               -- art. 10 bis
  mesi_inattivita_max   int not null default 24,              -- art. 6
  eta_min               int not null default 18,              -- art. 20
  eta_max               int not null default 75,
  note                  text,
  updated_at            timestamptz not null default now()
);

-- Impostazioni generali (v1.6): es. codice_registrazione
create table if not exists impostazioni (
  chiave      text primary key,
  valore      text,
  updated_at  timestamptz not null default now()
);
alter table impostazioni enable row level security;

-- Log delle sincronizzazioni
create table if not exists sync_log (
  id          uuid primary key default gen_random_uuid(),
  tipo        text not null check (tipo in ('swen','albo')),
  esito       text not null,
  inseriti    int default 0,
  aggiornati  int default 0,
  segnalati   int default 0,
  dettagli    jsonb,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2. FUNZIONI DI SUPPORTO
-- ---------------------------------------------------------------------

-- Vero per i membri del comitato. Vero anche quando non c'è un utente loggato
-- (SQL Editor, service role, Edge Function): quel contesto è amministrativo per definizione;
-- gli utenti anonimi non arrivano qui perché nessuna policy è concessa al ruolo anon.
-- v1.4: il contesto senza utente vale come comitato SOLO se non è il ruolo anon (chiave pubblica senza login).
create or replace function is_comitato() returns boolean
language sql stable security definer set search_path = public as $$
  select (auth.uid() is null and coalesce(auth.role(),'') <> 'anon')
      or exists (select 1 from profili where id = auth.uid() and ruolo = 'comitato');
$$;

-- Vero per gli account attivati dal comitato (o per il contesto amministrativo senza utente)
create or replace function is_attivo() returns boolean
language sql stable security definer set search_path = public as $$
  select (auth.uid() is null and coalesce(auth.role(),'') <> 'anon')
      or exists (select 1 from profili where id = auth.uid() and ruolo in ('comitato','giudice'));
$$;

create or replace function my_giudice_id() returns uuid
language sql stable security definer set search_path = public as $$
  select giudice_id from profili where id = auth.uid();
$$;

-- updated_at automatico
create or replace function set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['giudici','gare','profili','disponibilita','convocazioni','rimborsi','corsi'] loop
    execute format('drop trigger if exists %I_updated_at on %I', t, t);
    execute format('create trigger %I_updated_at before update on %I for each row execute function set_updated_at()', t, t);
  end loop;
end $$;

-- Creazione automatica del profilo alla registrazione di un utente Auth.
-- v1.3: ruolo "ospite" e nessun collegamento automatico: l'attivazione (ruolo + giudice) la fa il comitato
-- dall'app, che mostra come suggerimento l'eventuale giudice con la stessa email.
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare atteso text;
begin
  -- v1.6: codice di registrazione (se impostato dal comitato) passato dall'app nei metadati dell'utente
  select valore into atteso from impostazioni where chiave = 'codice_registrazione';
  if atteso is not null and atteso <> '' and coalesce(new.raw_user_meta_data->>'codice_registrazione','') <> atteso then
    raise exception 'Codice di registrazione non valido';
  end if;
  insert into profili (id, email, ruolo, giudice_id)
  values (new.id, new.email, 'ospite', null)
  on conflict (id) do nothing;
  return new;
end $$;

-- Verifica del codice prima della registrazione (chiamabile senza login; risponde solo vero/falso)
create or replace function verifica_codice_registrazione(p_codice text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select valore from impostazioni where chiave = 'codice_registrazione'), '') in ('', coalesce(p_codice,''));
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users for each row execute function handle_new_user();

-- Il giudice può modificare solo i propri dati di contatto; i campi "di comitato" restano bloccati
create or replace function giudici_protect_fields() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if is_comitato() then return new; end if;
  if new.qualifica is distinct from old.qualifica
     or new.in_affiancamento is distinct from old.in_affiancamento
     or new.affiancamenti_richiesti is distinct from old.affiancamenti_richiesti
     or new.attivo is distinct from old.attivo
     or new.albo_id is distinct from old.albo_id
     or new.origine is distinct from old.origine
     or new.presente_in_albo is distinct from old.presente_in_albo
     or new.note is distinct from old.note
     or new.macroarea is distinct from old.macroarea then
    raise exception 'Campo modificabile solo dal comitato';
  end if;
  return new;
end $$;
drop trigger if exists giudici_protect on giudici;
create trigger giudici_protect before update on giudici
  for each row execute function giudici_protect_fields();

-- Transizioni di stato delle convocazioni + storico + regole
create or replace function convocazioni_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  comitato boolean := is_comitato();
  g giudici%rowtype;
  ga gare%rowtype;
  altri int;
begin
  select * into g  from giudici where id = new.giudice_id;
  select * into ga from gare    where id = new.gara_id;

  if tg_op = 'INSERT' then
    if not comitato then raise exception 'Solo il comitato può creare convocazioni'; end if;
    -- già convocato per questa gara (una precedente annullata/rifiutata non conta)
    if exists (select 1 from convocazioni where gara_id = new.gara_id and giudice_id = new.giudice_id
                 and stato not in ('rifiutata','annullata')) then
      raise exception 'Il giudice ha già una convocazione attiva per questa gara';
    end if;
    -- doppia convocazione lo stesso giorno (blocco)
    if exists (
      select 1 from convocazioni c join gare x on x.id = c.gara_id
      where c.giudice_id = new.giudice_id and c.stato not in ('rifiutata','annullata')
        and x.id <> new.gara_id
        and x.data_inizio <= coalesce(ga.data_fine, ga.data_inizio)
        and coalesce(x.data_fine, x.data_inizio) >= ga.data_inizio
    ) then raise exception 'Il giudice ha già una convocazione in quelle date'; end if;
    -- coordinatore: solo nazionali su gare nazionali/internazionali
    if new.ruolo = 'coordinatore' and (g.qualifica <> 'nazionale'
       or coalesce(ga.classificazione,'') not in ('Nazionale','Internazionale','Europeo')) then
      raise exception 'Il ruolo Coordinatore è riservato ai giudici Nazionali nelle gare nazionali/internazionali (art. 7 ter)';
    end if;
    -- regionale su gara nazionale: serve deroga esplicita
    if g.qualifica = 'regionale' and coalesce(ga.classificazione,'') in ('Nazionale','Internazionale','Europeo')
       and not new.deroga then
      raise exception 'Giudice Regionale su gara nazionale: richiede deroga del comitato (art. 7 ter)';
    end if;
    -- in affiancamento: il ruolo deve essere "affiancamento"
    if g.in_affiancamento and new.ruolo <> 'affiancamento' then
      raise exception 'Giudice in affiancamento: il ruolo deve essere "affiancamento" (art. 2)';
    end if;
  end if;

  if tg_op = 'UPDATE' and new.stato is distinct from old.stato then
    if not comitato then
      -- il giudice può solo accettare o rifiutare una proposta a lui rivolta
      if old.giudice_id <> my_giudice_id() or old.stato <> 'proposta'
         or new.stato not in ('accettata','rifiutata') then
        raise exception 'Transizione non consentita';
      end if;
    end if;
    -- conferma: un affiancamento non può essere l'unico giudice confermato della gara
    if new.stato = 'confermata' and new.ruolo = 'affiancamento' then
      select count(*) into altri from convocazioni
       where gara_id = new.gara_id and id <> new.id and ruolo <> 'affiancamento'
         and stato in ('confermata','accettata','svolta');
      if altri = 0 then
        raise exception 'Un giudice in affiancamento deve essere affiancato da un giudice riconosciuto (art. 2)';
      end if;
    end if;
  elsif tg_op = 'UPDATE' and not comitato then
    raise exception 'Solo il comitato può modificare la convocazione';
  end if;
  return new;
end $$;
drop trigger if exists convocazioni_guard_trg on convocazioni;
create trigger convocazioni_guard_trg before insert or update on convocazioni
  for each row execute function convocazioni_guard();

-- Storico: scritto DOPO l'insert/update (la riga deve già esistere per la foreign key)
create or replace function convocazioni_storico_fn() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.stato is distinct from old.stato then
    insert into convocazioni_storico (convocazione_id, stato_da, stato_a, autore, note)
    values (new.id, case when tg_op = 'INSERT' then null else old.stato end, new.stato, auth.uid(),
            case when new.stato = 'rifiutata' then new.motivo_rifiuto else null end);
  end if;
  return new;
end $$;
drop trigger if exists convocazioni_storico_trg on convocazioni;
create trigger convocazioni_storico_trg after insert or update on convocazioni
  for each row execute function convocazioni_storico_fn();

-- Presenze ai corsi: il giudice cambia solo la propria dichiarazione (partecipa / non partecipa)
-- e solo finché il comitato non ha registrato l'esito
create or replace function presenze_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not is_comitato() then
    if old.giudice_id is distinct from my_giudice_id() then raise exception 'Non autorizzato'; end if;
    if old.stato not in ('invitato','partecipa','non_partecipa') then raise exception 'Presenza già registrata dal comitato'; end if;
    if new.stato not in ('partecipa','non_partecipa') then raise exception 'Il giudice può solo dichiarare se partecipa'; end if;
    if new.giudice_id <> old.giudice_id or new.corso_id <> old.corso_id then raise exception 'Non autorizzato'; end if;
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists presenze_guard_trg on corsi_presenze;
create trigger presenze_guard_trg before update on corsi_presenze
  for each row execute function presenze_guard();

-- Invita tutti i giudici attivi a un corso (idempotente)
create or replace function invita_tutti(p_corso uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not is_comitato() then raise exception 'Operazione riservata al comitato'; end if;
  insert into corsi_presenze (corso_id, giudice_id)
  select p_corso, g.id from giudici g
   where g.attivo and not exists (select 1 from corsi_presenze p where p.corso_id = p_corso and p.giudice_id = g.id);
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function invita_tutti(uuid) to authenticated;
revoke execute on function invita_tutti(uuid) from public, anon;

-- Rimborso: calcolo totale + regole di modifica
create or replace function rimborsi_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  comitato boolean := is_comitato();
  spese_tot numeric := 0;
  c convocazioni%rowtype;
begin
  select * into c from convocazioni where id = new.convocazione_id;
  if not comitato then
    if c.giudice_id is distinct from my_giudice_id() then
      raise exception 'Non autorizzato';
    end if;
    if tg_op = 'UPDATE' and old.stato in ('approvato','liquidato') then
      raise exception 'Rimborso già approvato: modificabile solo dal comitato';
    end if;
    if new.stato not in ('da_compilare','compilato') then
      raise exception 'Il giudice può solo compilare il rimborso';
    end if;
    if new.modalita = 'manuale' then
      raise exception 'La modalità manuale è riservata al comitato';
    end if;
  end if;
  select coalesce(sum((e->>'importo')::numeric),0) into spese_tot
    from jsonb_array_elements(coalesce(new.spese,'[]'::jsonb)) e;
  new.totale := case new.modalita
    when 'km_spese'   then round(new.km * new.tariffa_km + spese_tot, 2)
    when 'gettone_km' then round(new.gettone + new.km * new.tariffa_km + spese_tot, 2)
    when 'manuale'    then coalesce(new.importo_manuale, 0)
  end;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists rimborsi_guard_trg on rimborsi;
create trigger rimborsi_guard_trg before insert or update on rimborsi
  for each row execute function rimborsi_guard();

-- ---------------------------------------------------------------------
-- 3. VISTE PER REPORT
-- ---------------------------------------------------------------------

-- Le viste vengono ricreate da zero: con CREATE OR REPLACE non si possono aggiungere colonne alle tabelle sottostanti (c.* / ga.*)
drop view if exists v_copertura_gare;
drop view if exists v_stato_giudici;
drop view if exists v_convocazioni;
drop view if exists giudici_pubblici;

-- v1.6: dati dei giudici visibili ai colleghi (solo l'essenziale per riconoscere la squadra di gara).
-- Vista "definer" (bypassa le policy di giudici) ma filtrata su is_attivo(): gli ospiti non vedono nulla.
create view giudici_pubblici as
select id, cognome, nome, qualifica, in_affiancamento, attivo, provincia, regione, societa, swen_id, presente_in_albo
from giudici where is_attivo();

-- Convocazioni con dati gara e giudice
create or replace view v_convocazioni as
select c.*, g.cognome, g.nome, g.qualifica, g.in_affiancamento,
       ga.titolo, ga.data_inizio, ga.data_fine, ga.anno_sportivo, ga.tipo_codice, ga.tipo_descrizione,
       ga.classificazione, ga.regione as gara_regione, ga.provincia as gara_provincia,
       ga.societa_organizzatrice, ga.giudice_swen, ga.stato as gara_stato,
       r.totale as rimborso_totale, r.stato as rimborso_stato,
       exists (select 1 from referti f where f.convocazione_id = c.id) as referto_caricato
from convocazioni c
join giudici_pubblici g on g.id = c.giudice_id
join gare    ga on ga.id = c.gara_id
left join rimborsi r on r.convocazione_id = c.id;

-- Stato di mantenimento per giudice (art. 6, 10 bis, 13, 20)
create or replace view v_stato_giudici as
select g.id, g.cognome, g.nome, g.qualifica, g.in_affiancamento, g.attivo, g.regione, g.provincia,
       (select count(*) from convocazioni c join gare x on x.id = c.gara_id
         where c.giudice_id = g.id and c.stato = 'svolta'
           and x.data_inizio >= current_date - interval '12 months')            as servizi_12m,
       (select count(*) from aggiornamenti a
         where a.giudice_id = g.id and a.data >= current_date - interval '12 months')
       + (select count(*) from corsi_presenze p join corsi k on k.id = p.corso_id
         where p.giudice_id = g.id and p.stato = 'presente' and k.data >= current_date - interval '12 months') as aggiornamenti_12m,
       (select max(x.data_inizio) from convocazioni c join gare x on x.id = c.gara_id
         where c.giudice_id = g.id and c.stato = 'svolta')                        as ultimo_servizio,
       (select count(*) from convocazioni c
         where c.giudice_id = g.id and c.ruolo = 'affiancamento' and c.stato = 'svolta') as affiancamenti_svolti,
       g.affiancamenti_richiesti,
       g.scadenza_tessera, g.scadenza_certificato,
       case when g.data_nascita is null then null
            else extract(year from age(current_date, g.data_nascita))::int end as eta,
       (g.scadenza_tessera     is not null and g.scadenza_tessera     < current_date) as tessera_scaduta,
       (g.scadenza_certificato is not null and g.scadenza_certificato < current_date) as certificato_scaduto
from giudici g;

-- Copertura gare: fabbisogno vs confermati
create or replace view v_copertura_gare as
select ga.*,
       (select count(*) from convocazioni c where c.gara_id = ga.id
          and c.stato in ('confermata','svolta') and c.ruolo <> 'affiancamento') as giudici_confermati,
       (select count(*) from convocazioni c where c.gara_id = ga.id
          and c.stato in ('proposta','accettata'))                                as convocazioni_in_corso,
       (select count(*) from disponibilita d where d.gara_id = ga.id and d.stato = 'disponibile') as disponibili,
       (select string_agg(g.cognome || ' ' || g.nome, ', ')
          from convocazioni c join giudici_pubblici g on g.id = c.giudice_id
         where c.gara_id = ga.id and c.stato in ('confermata','svolta'))          as giudici_confermati_nomi
from gare ga;

-- v1.6: le viste applicano le policy delle tabelle di chi interroga (prima giravano come proprietario e le ignoravano)
alter view v_convocazioni   set (security_invoker = true);
alter view v_stato_giudici  set (security_invoker = true);
alter view v_copertura_gare set (security_invoker = true);

-- ---------------------------------------------------------------------
-- 4. ROW LEVEL SECURITY
-- ---------------------------------------------------------------------

alter table giudici              enable row level security;
alter table gare                 enable row level security;
alter table profili              enable row level security;
alter table disponibilita        enable row level security;
alter table convocazioni         enable row level security;
alter table convocazioni_storico enable row level security;
alter table aggiornamenti        enable row level security;
alter table rimborsi             enable row level security;
alter table referti              enable row level security;
alter table parametri            enable row level security;
alter table sync_log             enable row level security;

-- Pulizia policy esistenti (per riesecuzione)
do $$
declare r record;
begin
  for r in select policyname, tablename from pg_policies where schemaname = 'public' loop
    execute format('drop policy if exists %I on %I', r.policyname, r.tablename);
  end loop;
end $$;

-- giudici: la riga completa (contatti, indirizzo, scadenze, note) la leggono solo il comitato e l'interessato;
-- i colleghi passano dalla vista giudici_pubblici. Scrive il comitato; il giudice aggiorna la propria riga (campi protetti da trigger)
create policy giudici_select on giudici for select to authenticated using (is_comitato() or id = my_giudice_id());
create policy giudici_insert on giudici for insert to authenticated with check (is_comitato());
create policy giudici_update on giudici for update to authenticated
  using (is_comitato() or id = my_giudice_id()) with check (is_comitato() or id = my_giudice_id());
create policy giudici_delete on giudici for delete to authenticated using (is_comitato());

-- gare: lettura a tutti, scrittura comitato
create policy gare_select on gare for select to authenticated using (is_attivo());
create policy gare_write  on gare for all    to authenticated using (is_comitato()) with check (is_comitato());

-- profili: ognuno vede il proprio; il comitato vede e gestisce tutti
create policy profili_select on profili for select to authenticated using (id = auth.uid() or is_comitato());
create policy profili_write  on profili for all    to authenticated using (is_comitato()) with check (is_comitato());

-- disponibilità: lettura a tutti; scrittura propria o comitato
create policy disp_select on disponibilita for select to authenticated using (is_attivo());
create policy disp_write  on disponibilita for all to authenticated
  using (is_comitato() or giudice_id = my_giudice_id())
  with check (is_comitato() or giudice_id = my_giudice_id());

-- convocazioni: lettura a tutti (squadra di gara visibile); insert/delete comitato;
-- update comitato o proprio giudice (transizioni controllate dal trigger)
create policy conv_select on convocazioni for select to authenticated using (is_attivo());
create policy conv_insert on convocazioni for insert to authenticated with check (is_comitato());
create policy conv_update on convocazioni for update to authenticated
  using (is_comitato() or giudice_id = my_giudice_id())
  with check (is_comitato() or giudice_id = my_giudice_id());
create policy conv_delete on convocazioni for delete to authenticated using (is_comitato());

create policy storico_select on convocazioni_storico for select to authenticated using (is_attivo());

-- aggiornamenti "esterni" (registrati a mano): lettura attivi; scrittura SOLO comitato (v1.4)
create policy agg_select on aggiornamenti for select to authenticated using (is_attivo());
create policy agg_write  on aggiornamenti for all to authenticated using (is_comitato()) with check (is_comitato());
-- corsi e presenze (v1.4)
create policy corsi_select on corsi for select to authenticated using (is_attivo());
create policy corsi_write  on corsi for all    to authenticated using (is_comitato()) with check (is_comitato());
create policy pres_select  on corsi_presenze for select to authenticated using (is_attivo());
create policy pres_insert  on corsi_presenze for insert to authenticated with check (is_comitato());
create policy pres_update  on corsi_presenze for update to authenticated
  using (is_comitato() or giudice_id = my_giudice_id()) with check (is_comitato() or giudice_id = my_giudice_id());
create policy pres_delete  on corsi_presenze for delete to authenticated using (is_comitato());

-- rimborsi e referti: solo propri o comitato
create policy rimb_all on rimborsi for all to authenticated
  using (is_comitato() or exists (select 1 from convocazioni c where c.id = convocazione_id and c.giudice_id = my_giudice_id()))
  with check (is_comitato() or exists (select 1 from convocazioni c where c.id = convocazione_id and c.giudice_id = my_giudice_id()));

create policy ref_select on referti for select to authenticated
  using (is_comitato() or exists (select 1 from convocazioni c where c.id = convocazione_id and c.giudice_id = my_giudice_id()));
create policy ref_insert on referti for insert to authenticated
  with check (is_comitato() or exists (select 1 from convocazioni c where c.id = convocazione_id and c.giudice_id = my_giudice_id()));
create policy ref_delete on referti for delete to authenticated using (is_comitato());

-- impostazioni: solo comitato (il codice di registrazione non deve essere leggibile dai giudici)
create policy imp_all on impostazioni for all to authenticated using (is_comitato()) with check (is_comitato());
-- parametri e log: lettura a tutti, scrittura comitato
create policy par_select on parametri for select to authenticated using (is_attivo());
create policy par_write  on parametri for all    to authenticated using (is_comitato()) with check (is_comitato());
create policy log_select on sync_log  for select to authenticated using (is_attivo());
create policy log_write  on sync_log  for insert to authenticated with check (is_comitato());

-- ---------------------------------------------------------------------
-- 5. STORAGE (bucket privato per i referti)
-- ---------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit)
values ('referti', 'referti', false, 10485760)
on conflict (id) do nothing;

drop policy if exists referti_storage_read   on storage.objects;
drop policy if exists referti_storage_insert on storage.objects;
drop policy if exists referti_storage_delete on storage.objects;

-- Percorso file: <convocazione_id>/<nome_file>
create policy referti_storage_read on storage.objects for select to authenticated
  using (bucket_id = 'referti' and (is_comitato() or exists (
    select 1 from convocazioni c
    where c.id::text = split_part(name, '/', 1) and c.giudice_id = my_giudice_id())));
create policy referti_storage_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'referti' and (is_comitato() or exists (
    select 1 from convocazioni c
    where c.id::text = split_part(name, '/', 1) and c.giudice_id = my_giudice_id())));
create policy referti_storage_delete on storage.objects for delete to authenticated
  using (bucket_id = 'referti' and is_comitato());

-- ---------------------------------------------------------------------
-- 6. DATI INIZIALI
-- ---------------------------------------------------------------------

insert into parametri (anno_sportivo, note)
values ('2026/2027', 'Valori di rimborso da impostare secondo la misura stabilita dalla Commissione (art. 16)')
on conflict (anno_sportivo) do nothing;

-- =====================================================================
--  PRIMO ACCESSO
--  1. Registrare il primo utente dall'app (o da Authentication > Users).
--  2. Eseguire, sostituendo l'email:
--       update profili set ruolo = 'comitato' where email = 'tua@email.it';
--  Da quel momento gli altri ruoli si assegnano dall'app.
-- =====================================================================

-- =====================================================================
--  AGGIORNAMENTO v1.2 — albo da arco.swen e riconciliazione automatica
-- =====================================================================

-- (colonne v1.2/v1.4 aggiunte subito dopo la creazione delle tabelle, vedi sezione 1)

-- Normalizza "COGNOME NOME" per il confronto con il campo Giudice di arco.swen
create or replace function nome_norm(t text) returns text
language sql immutable as $$
  select regexp_replace(upper(coalesce(trim(t),'')), '\s+', ' ', 'g');
$$;

-- Riconciliazione con arco.swen:
--  1. le gare arco.swen passate ancora "programmate" diventano "svolte";
--  2. per ogni gara con un giudice registrato sul portale che corrisponde a un giudice in elenco:
--     - se non c'è convocazione attiva, la crea (ruolo giudice / affiancamento; deroga se regionale su nazionale);
--     - proposta/accettata → confermata (la registrazione sul portale è la designazione ufficiale);
--     - confermata e gara passata → svolta.
--  Le regole dei trigger restano valide: i casi rifiutati finiscono nell'elenco "errori" del risultato.
create or replace function riconcilia_swen() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r gare%rowtype; g giudici%rowtype; c convocazioni%rowtype;
  n_chiuse int := 0; n_ins int := 0; n_conf int := 0; n_sv int := 0; n_future int := 0;
  errs text[] := '{}'; chiuse text[] := '{}'; passata boolean; nm text;
begin
  if not is_comitato() then raise exception 'Operazione riservata al comitato'; end if;

  -- le gare arco.swen passate ancora "in programma" si considerano svolte (evento avvenuto)
  update gare set stato = 'svolta'
   where origine = 'swen' and stato = 'programmata' and coalesce(data_fine, data_inizio) < current_date;
  get diagnostics n_chiuse = row_count;

  for r in select * from gare where giudice_swen is not null and stato <> 'annullata' loop
    nm := nome_norm(r.giudice_swen);
    select * into g from giudici
     where nome_norm(cognome || ' ' || nome) = nm or nome_norm(nome || ' ' || cognome) = nm
     order by attivo desc limit 1;
    if not found then continue; end if;
    passata := coalesce(r.data_fine, r.data_inizio) < current_date;
    begin
      select * into c from convocazioni
       where gara_id = r.id and giudice_id = g.id and stato not in ('rifiutata','annullata') limit 1;

      if not passata then
        -- GARA FUTURA (regola B, art. 7 quater: designa il comitato): mai creare;
        -- se il comitato ha già proposto lo stesso giudice, il portale concorda → conferma
        if found and c.stato in ('proposta','accettata') then
          update convocazioni set stato = 'confermata' where id = c.id; n_conf := n_conf + 1;
        elsif not found then
          n_future := n_future + 1;   -- segnalato nel report, nessuna azione
        end if;
        continue;
      end if;

      -- GARA PASSATA: la registrazione sul portale è l'unica traccia → si crea la convocazione
      if not found then
        insert into convocazioni (gara_id, giudice_id, ruolo, deroga, note)
        values (r.id, g.id,
                case when g.in_affiancamento then 'affiancamento' else 'giudice' end,
                (g.qualifica = 'regionale' and coalesce(r.classificazione,'') in ('Nazionale','Internazionale','Europeo')),
                'Registrato su arco.swen')
        returning * into c;
        n_ins := n_ins + 1;
      end if;
      if c.stato in ('proposta','accettata') then
        update convocazioni set stato = 'confermata' where id = c.id; c.stato := 'confermata'; n_conf := n_conf + 1;
      end if;
      -- "svolta" automatica solo se il portale conferma che la gara si è tenuta (chiusa con classifica);
      -- altrimenti resta "confermata" e compare in Home tra le gare da chiudere (svolta/assente)
      if c.stato = 'confermata' and r.swen_stato = 'Chiuso' and coalesce(r.swen_classifica, false) then
        update convocazioni set stato = 'svolta' where id = c.id; n_sv := n_sv + 1;
        chiuse := chiuse || (to_char(r.data_inizio,'DD/MM/YYYY') || ' ' || r.titolo || ' — ' || g.cognome || ' ' || g.nome);
      end if;
    exception when others then
      errs := errs || (to_char(r.data_inizio,'DD/MM/YYYY') || ' ' || r.titolo || ' — ' || r.giudice_swen || ': ' || sqlerrm);
    end;
  end loop;

  return jsonb_build_object('gare_chiuse', n_chiuse, 'convocazioni_create', n_ins,
                            'confermate', n_conf, 'svolte', n_sv, 'future_senza_convocazione', n_future,
                            'chiuse_automaticamente', to_jsonb(chiuse), 'errori', to_jsonb(errs));
end $$;
grant execute on function riconcilia_swen() to authenticated;
-- v1.4: nessuna funzione eseguibile con la chiave pubblica senza login
revoke execute on function riconcilia_swen() from public, anon;
revoke execute on function nome_norm(text) from anon;

-- =====================================================================
--  AGGIORNAMENTO v1.3 — account ospite
--  Le modifiche sono già integrate sopra (tabella profili, is_attivo(), handle_new_user, policy).
--  Gli account esistenti con ruolo 'giudice' non collegati a un giudice vengono riportati a 'ospite'.
-- =====================================================================
update profili set ruolo = 'ospite' where ruolo = 'giudice' and giudice_id is null;

-- =====================================================================
--  AGGIORNAMENTO v1.5 — notifiche (in app, push, email)
--  Ogni evento rilevante inserisce una riga in "notifiche" per ogni destinatario.
--  L'app la mostra subito (Realtime); un Database Webhook su INSERT chiama la
--  Edge Function "notifica" che invia push (Web Push/VAPID) ed email.
-- =====================================================================

create table if not exists notifiche (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  tipo          text not null,                -- convocazione | corso | rimborso | promemoria | comitato | sistema
  titolo        text not null,
  corpo         text,
  dati          jsonb,                        -- es. {"gara_id":"...","corso_id":"...","tab":"convocazioni"}
  letta         boolean not null default false,
  inviata_push  boolean,
  inviata_email boolean,
  created_at    timestamptz not null default now()
);
create index if not exists notifiche_user_idx on notifiche (user_id, letta, created_at desc);

create table if not exists push_iscrizioni (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  endpoint    text not null unique,
  p256dh      text not null,
  auth        text not null,
  user_agent  text,
  created_at  timestamptz not null default now(),
  ultimo_uso  timestamptz
);

create table if not exists notifiche_preferenze (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  push        boolean not null default true,
  email       boolean not null default false,
  eventi      jsonb not null default '{"convocazione":true,"corso":true,"rimborso":true,"promemoria":true,"comitato":true}'::jsonb,
  updated_at  timestamptz not null default now()
);

alter table notifiche            enable row level security;
alter table push_iscrizioni      enable row level security;
alter table notifiche_preferenze enable row level security;

drop policy if exists notif_select on notifiche;
drop policy if exists notif_insert on notifiche;
drop policy if exists notif_update on notifiche;
drop policy if exists notif_delete on notifiche;
drop policy if exists push_all     on push_iscrizioni;
drop policy if exists pref_all     on notifiche_preferenze;
create policy notif_select on notifiche for select to authenticated using (user_id = auth.uid());
-- un utente può creare notifiche solo per se stesso (serve al pulsante "Invia una prova")
create policy notif_insert on notifiche for insert to authenticated with check (user_id = auth.uid());
create policy notif_update on notifiche for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy notif_delete on notifiche for delete to authenticated using (user_id = auth.uid());
create policy push_all on push_iscrizioni for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy pref_all on notifiche_preferenze for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Inserisce una notifica per un giudice (se ha un account) o per tutti i membri del comitato
create or replace function notifica_giudice(p_giudice uuid, p_tipo text, p_titolo text, p_corpo text, p_dati jsonb default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into notifiche (user_id, tipo, titolo, corpo, dati)
  select p.id, p_tipo, p_titolo, p_corpo, p_dati from profili p
   where p.giudice_id = p_giudice and p.ruolo in ('giudice','comitato');
end $$;
create or replace function notifica_comitato(p_tipo text, p_titolo text, p_corpo text, p_dati jsonb default null, p_escludi uuid default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into notifiche (user_id, tipo, titolo, corpo, dati)
  select p.id, p_tipo, p_titolo, p_corpo, p_dati from profili p
   where p.ruolo = 'comitato' and (p_escludi is null or p.id <> p_escludi);
end $$;
revoke execute on function notifica_giudice(uuid,text,text,text,jsonb) from public, anon, authenticated;
revoke execute on function notifica_comitato(text,text,text,jsonb,uuid) from public, anon, authenticated;

-- Convocazioni: proposta/conferma/annullamento → giudice; risposta del giudice → comitato
create or replace function notif_convocazioni() returns trigger
language plpgsql security definer set search_path = public as $$
declare ga gare%rowtype; g giudici%rowtype; d jsonb; quando text;
begin
  select * into ga from gare where id = new.gara_id;
  select * into g  from giudici where id = new.giudice_id;
  d := jsonb_build_object('gara_id', new.gara_id, 'convocazione_id', new.id);
  quando := to_char(ga.data_inizio, 'DD/MM/YYYY');
  if tg_op = 'INSERT' then
    if new.stato = 'proposta' then
      perform notifica_giudice(new.giudice_id, 'convocazione', 'Nuova convocazione: ' || ga.titolo, quando || ' · rispondi dall''app (accetto / rifiuto)', d || '{"tab":"convocazioni"}');
    elsif new.stato = 'confermata' then
      perform notifica_giudice(new.giudice_id, 'convocazione', 'Convocazione confermata: ' || ga.titolo, quando || ' · ' || coalesce(ga.comune,''), d || '{"tab":"convocazioni"}');
    end if;
  elsif new.stato is distinct from old.stato then
    if new.stato = 'confermata' then
      perform notifica_giudice(new.giudice_id, 'convocazione', 'Convocazione confermata: ' || ga.titolo, quando || ' · ' || coalesce(ga.comune,''), d || '{"tab":"convocazioni"}');
    elsif new.stato = 'annullata' then
      perform notifica_giudice(new.giudice_id, 'convocazione', 'Convocazione annullata: ' || ga.titolo, quando, d || '{"tab":"convocazioni"}');
    elsif new.stato in ('accettata','rifiutata') then
      perform notifica_comitato('comitato', g.cognome || ' ' || g.nome || ' ha ' || case when new.stato='accettata' then 'accettato' else 'rifiutato' end || ': ' || ga.titolo,
                                quando || case when new.stato='rifiutata' then ' · motivo: ' || coalesce(new.motivo_rifiuto,'') else '' end, d, auth.uid());
    end if;
  end if;
  return new;
end $$;
drop trigger if exists notif_convocazioni_trg on convocazioni;
create trigger notif_convocazioni_trg after insert or update on convocazioni
  for each row execute function notif_convocazioni();

-- Corsi: invito → giudice
create or replace function notif_presenze() returns trigger
language plpgsql security definer set search_path = public as $$
declare k corsi%rowtype;
begin
  select * into k from corsi where id = new.corso_id;
  if tg_op = 'INSERT' and k.stato = 'programmato' and k.data >= current_date then
    perform notifica_giudice(new.giudice_id, 'corso', 'Invito: ' || k.titolo, to_char(k.data,'DD/MM/YYYY') || coalesce(' · ' || k.luogo,'') || ' · dichiara se partecipi',
                             jsonb_build_object('corso_id', k.id, 'tab', 'gare', 'sez', 'aggiornamenti'));
  end if;
  return new;
end $$;
drop trigger if exists notif_presenze_trg on corsi_presenze;
create trigger notif_presenze_trg after insert on corsi_presenze
  for each row execute function notif_presenze();

-- Rimborsi: compilato → comitato; approvato/liquidato → giudice
create or replace function notif_rimborsi() returns trigger
language plpgsql security definer set search_path = public as $$
declare c convocazioni%rowtype; ga gare%rowtype; g giudici%rowtype;
begin
  if tg_op = 'UPDATE' and new.stato is not distinct from old.stato then return new; end if;
  select * into c from convocazioni where id = new.convocazione_id;
  select * into ga from gare where id = c.gara_id;
  select * into g from giudici where id = c.giudice_id;
  if new.stato = 'compilato' then
    perform notifica_comitato('comitato', 'Rimborso da approvare: ' || g.cognome || ' ' || g.nome, ga.titolo || ' · ' || replace(to_char(new.totale,'FM999990.00'),'.',',') || ' €', jsonb_build_object('tab','rimborsi','convocazione_id', c.id), auth.uid());
  elsif new.stato in ('approvato','liquidato') then
    perform notifica_giudice(c.giudice_id, 'rimborso', 'Rimborso ' || new.stato || ': ' || ga.titolo, replace(to_char(new.totale,'FM999990.00'),'.',',') || ' €', jsonb_build_object('tab','convocazioni','convocazione_id', c.id));
  end if;
  return new;
end $$;
drop trigger if exists notif_rimborsi_trg on rimborsi;
create trigger notif_rimborsi_trg after insert or update on rimborsi
  for each row execute function notif_rimborsi();

-- Disponibilità su gara scoperta → comitato
create or replace function notif_disponibilita() returns trigger
language plpgsql security definer set search_path = public as $$
declare ga gare%rowtype; g giudici%rowtype; conf int;
begin
  if new.stato <> 'disponibile' or (tg_op = 'UPDATE' and old.stato = 'disponibile') then return new; end if;
  select * into ga from gare where id = new.gara_id;
  select * into g from giudici where id = new.giudice_id;
  select count(*) into conf from convocazioni where gara_id = ga.id and stato in ('confermata','svolta') and ruolo <> 'affiancamento';
  if ga.stato = 'programmata' and ga.data_inizio >= current_date and conf < ga.fabbisogno_giudici then
    perform notifica_comitato('comitato', 'Disponibile: ' || g.cognome || ' ' || g.nome, ga.titolo || ' · ' || to_char(ga.data_inizio,'DD/MM/YYYY') || coalesce(' · ' || new.note, ''), jsonb_build_object('gara_id', ga.id));
  end if;
  return new;
end $$;
drop trigger if exists notif_disponibilita_trg on disponibilita;
create trigger notif_disponibilita_trg after insert or update on disponibilita
  for each row execute function notif_disponibilita();

-- Nuovo account → comitato
create or replace function notif_profili() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform notifica_comitato('comitato', 'Nuovo account da attivare', coalesce(new.email,''), '{"tab":"impostazioni"}'::jsonb);
  return new;
end $$;
drop trigger if exists notif_profili_trg on profili;
create trigger notif_profili_trg after insert on profili
  for each row execute function notif_profili();

-- Promemoria: gare confermate tra 3 giorni e corsi domani (da eseguire una volta al giorno)
create or replace function invia_promemoria() returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0; r record;
begin
  for r in select c.giudice_id, c.id as cid, ga.id as gid, ga.titolo, ga.data_inizio, ga.comune, ga.indirizzo
             from convocazioni c join gare ga on ga.id = c.gara_id
            where c.stato = 'confermata' and ga.data_inizio = current_date + 3 loop
    perform notifica_giudice(r.giudice_id, 'promemoria', 'Tra 3 giorni: ' || r.titolo, to_char(r.data_inizio,'DD/MM/YYYY') || coalesce(' · ' || r.comune,'') || coalesce(', ' || r.indirizzo,''), jsonb_build_object('gara_id', r.gid, 'tab', 'convocazioni'));
    n := n + 1;
  end loop;
  for r in select p.giudice_id, k.id as kid, k.titolo, k.data, k.luogo
             from corsi_presenze p join corsi k on k.id = p.corso_id
            where p.stato in ('partecipa','invitato') and k.stato = 'programmato' and k.data = current_date + 1 loop
    perform notifica_giudice(r.giudice_id, 'promemoria', 'Domani: ' || r.titolo, coalesce(r.luogo,''), jsonb_build_object('corso_id', r.kid, 'tab', 'gare', 'sez', 'aggiornamenti'));
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function invia_promemoria() from public, anon, authenticated;

-- Pianificazione giornaliera con pg_cron (se l'estensione è disponibile: Supabase → Database → Extensions → pg_cron)
do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule(jobid) from cron.job where jobname = 'gdg_promemoria';
  perform cron.schedule('gdg_promemoria', '0 7 * * *', $cron$ select invia_promemoria(); $cron$);   -- ore 07:00 UTC = 09:00 (ora legale) / 08:00 italiane
exception when others then
  raise notice 'pg_cron non disponibile: i promemoria giornalieri non sono pianificati (%).', sqlerrm;
end $$;

-- Realtime: l'app riceve subito le notifiche e i cambi sui dati (RLS applicata)
do $$
declare t text;
begin
  foreach t in array array['notifiche','convocazioni','disponibilita','corsi','corsi_presenze','rimborsi','gare'] loop
    begin
      execute format('alter publication supabase_realtime add table %I', t);
    exception when duplicate_object then null;
             when others then raise notice 'realtime non attivato per %: %', t, sqlerrm;
    end;
  end loop;
end $$;

-- Pulizia: notifiche più vecchie di 90 giorni
create or replace function pulisci_notifiche() returns void language sql security definer set search_path = public as $$
  delete from notifiche where created_at < now() - interval '90 days';
$$;

-- v1.7: diagnostica della catena notifiche → webhook (solo comitato).
-- Restituisce le ultime risposte ricevute dal webhook (tabella net._http_response di pg_net)
-- e lo stato delle ultime notifiche: serve a capire dall'app perché una push non parte.
create or replace function diagnostica_notifiche() returns jsonb
language plpgsql security definer set search_path = public as $$
declare risposte jsonb := '[]'; ultime jsonb := '[]'; iscr int := 0; pgnet boolean;
begin
  if not is_comitato() then raise exception 'Operazione riservata al comitato'; end if;
  select exists (select 1 from pg_extension where extname = 'pg_net') into pgnet;
  if pgnet then
    begin
      execute $q$ select coalesce(jsonb_agg(jsonb_build_object('quando', created, 'stato', status_code,
                          'errore', error_msg, 'risposta', left(content, 300)) order by created desc), '[]')
                  from (select * from net._http_response order by created desc limit 8) r $q$ into risposte;
    exception when others then risposte := to_jsonb('non leggibile: ' || sqlerrm);
    end;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('quando', created_at, 'titolo', titolo, 'tipo', tipo,
                  'inviata_push', inviata_push, 'inviata_email', inviata_email) order by created_at desc), '[]')
    into ultime from (select * from notifiche order by created_at desc limit 8) n;
  select count(*) into iscr from push_iscrizioni where user_id = auth.uid();
  return jsonb_build_object('pg_net', pgnet, 'risposte_webhook', risposte, 'ultime_notifiche', ultime, 'mie_iscrizioni_push', iscr);
end $$;
grant execute on function diagnostica_notifiche() to authenticated;
revoke execute on function diagnostica_notifiche() from public, anon;

-- =====================================================================
--  AGGIORNAMENTO v1.6 — privilegi delle funzioni
--  Nessuna funzione del progetto è eseguibile senza login (PUBLIC/anon); gli utenti loggati
--  eseguono solo ciò che serve all'app; le funzioni interne restano al solo contesto amministrativo.
-- =====================================================================
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as f from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prorettype <> 'trigger'::regtype loop
    execute format('revoke execute on function %s from public, anon', r.f);
    execute format('grant execute on function %s to authenticated', r.f);
  end loop;
end $$;
-- funzioni interne: né anon né utenti
revoke execute on function notifica_giudice(uuid,text,text,text,jsonb) from authenticated;
revoke execute on function notifica_comitato(text,text,text,jsonb,uuid) from authenticated;
revoke execute on function invia_promemoria() from authenticated;
revoke execute on function pulisci_notifiche() from authenticated;
-- l'unica funzione eseguibile senza login: verifica del codice di registrazione (vero/falso)
grant execute on function verifica_codice_registrazione(text) to anon;
-- le funzioni create in futuro nascono chiuse
do $$
begin
  execute 'alter default privileges in schema public revoke execute on functions from public';
  execute 'alter default privileges in schema public revoke execute on functions from anon';
  execute 'alter default privileges for role postgres in schema public revoke execute on functions from anon';
exception when others then raise notice 'default privileges: %', sqlerrm;
end $$;
