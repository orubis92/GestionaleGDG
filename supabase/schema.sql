-- =====================================================================
--  GestionaleGDG — schema Supabase (Postgres)  v1.0
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
  swen_partecipanti       int,
  swen_updated_at         timestamptz,
  ultima_sync             timestamptz,
  note                    text,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);
create index if not exists gare_data_idx on gare (data_inizio);
create index if not exists gare_anno_idx on gare (anno_sportivo);

-- Profili: collega l'utente Supabase Auth a un giudice e definisce il ruolo applicativo
create table if not exists profili (
  id          uuid primary key references auth.users (id) on delete cascade,
  email       text,
  ruolo       text not null default 'giudice' check (ruolo in ('comitato','giudice')),
  giudice_id  uuid references giudici (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

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
  unique (gara_id, giudice_id),
  check (stato <> 'rifiutata' or coalesce(length(trim(motivo_rifiuto)),0) > 0)
);
create index if not exists convocazioni_giudice_idx on convocazioni (giudice_id);
create index if not exists convocazioni_gara_idx on convocazioni (gara_id);

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
create or replace function is_comitato() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is null
      or exists (select 1 from profili where id = auth.uid() and ruolo = 'comitato');
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
  foreach t in array array['giudici','gare','profili','disponibilita','convocazioni','rimborsi'] loop
    execute format('drop trigger if exists %I_updated_at on %I', t, t);
    execute format('create trigger %I_updated_at before update on %I for each row execute function set_updated_at()', t, t);
  end loop;
end $$;

-- Creazione automatica del profilo alla registrazione di un utente Auth:
-- se esiste un giudice con la stessa email viene collegato; ruolo iniziale "giudice".
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare g uuid;
begin
  select id into g from giudici where lower(email) = lower(new.email) limit 1;
  insert into profili (id, email, ruolo, giudice_id)
  values (new.id, new.email, 'giudice', g)
  on conflict (id) do nothing;
  return new;
end $$;

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

-- Convocazioni con dati gara e giudice
create or replace view v_convocazioni as
select c.*, g.cognome, g.nome, g.qualifica, g.in_affiancamento,
       ga.titolo, ga.data_inizio, ga.data_fine, ga.anno_sportivo, ga.tipo_codice, ga.tipo_descrizione,
       ga.classificazione, ga.regione as gara_regione, ga.provincia as gara_provincia,
       ga.societa_organizzatrice, ga.giudice_swen, ga.stato as gara_stato,
       r.totale as rimborso_totale, r.stato as rimborso_stato,
       exists (select 1 from referti f where f.convocazione_id = c.id) as referto_caricato
from convocazioni c
join giudici g  on g.id  = c.giudice_id
join gare    ga on ga.id = c.gara_id
left join rimborsi r on r.convocazione_id = c.id;

-- Stato di mantenimento per giudice (art. 6, 10 bis, 13, 20)
create or replace view v_stato_giudici as
select g.id, g.cognome, g.nome, g.qualifica, g.in_affiancamento, g.attivo, g.regione, g.provincia,
       (select count(*) from convocazioni c join gare x on x.id = c.gara_id
         where c.giudice_id = g.id and c.stato = 'svolta'
           and x.data_inizio >= current_date - interval '12 months')            as servizi_12m,
       (select count(*) from aggiornamenti a
         where a.giudice_id = g.id and a.data >= current_date - interval '12 months') as aggiornamenti_12m,
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
          from convocazioni c join giudici g on g.id = c.giudice_id
         where c.gara_id = ga.id and c.stato in ('confermata','svolta'))          as giudici_confermati_nomi
from gare ga;

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

-- giudici: tutti gli utenti autenticati leggono (serve per vedere i colleghi in gara);
-- scrive il comitato; il giudice aggiorna la propria riga (campi protetti da trigger)
create policy giudici_select on giudici for select to authenticated using (true);
create policy giudici_insert on giudici for insert to authenticated with check (is_comitato());
create policy giudici_update on giudici for update to authenticated
  using (is_comitato() or id = my_giudice_id()) with check (is_comitato() or id = my_giudice_id());
create policy giudici_delete on giudici for delete to authenticated using (is_comitato());

-- gare: lettura a tutti, scrittura comitato
create policy gare_select on gare for select to authenticated using (true);
create policy gare_write  on gare for all    to authenticated using (is_comitato()) with check (is_comitato());

-- profili: ognuno vede il proprio; il comitato vede e gestisce tutti
create policy profili_select on profili for select to authenticated using (id = auth.uid() or is_comitato());
create policy profili_write  on profili for all    to authenticated using (is_comitato()) with check (is_comitato());

-- disponibilità: lettura a tutti; scrittura propria o comitato
create policy disp_select on disponibilita for select to authenticated using (true);
create policy disp_write  on disponibilita for all to authenticated
  using (is_comitato() or giudice_id = my_giudice_id())
  with check (is_comitato() or giudice_id = my_giudice_id());

-- convocazioni: lettura a tutti (squadra di gara visibile); insert/delete comitato;
-- update comitato o proprio giudice (transizioni controllate dal trigger)
create policy conv_select on convocazioni for select to authenticated using (true);
create policy conv_insert on convocazioni for insert to authenticated with check (is_comitato());
create policy conv_update on convocazioni for update to authenticated
  using (is_comitato() or giudice_id = my_giudice_id())
  with check (is_comitato() or giudice_id = my_giudice_id());
create policy conv_delete on convocazioni for delete to authenticated using (is_comitato());

create policy storico_select on convocazioni_storico for select to authenticated using (true);

-- aggiornamenti: lettura a tutti; scrittura comitato o proprio
create policy agg_select on aggiornamenti for select to authenticated using (true);
create policy agg_write  on aggiornamenti for all to authenticated
  using (is_comitato() or giudice_id = my_giudice_id())
  with check (is_comitato() or giudice_id = my_giudice_id());

-- rimborsi e referti: solo propri o comitato
create policy rimb_all on rimborsi for all to authenticated
  using (is_comitato() or exists (select 1 from convocazioni c where c.id = convocazione_id and c.giudice_id = my_giudice_id()))
  with check (is_comitato() or exists (select 1 from convocazioni c where c.id = convocazione_id and c.giudice_id = my_giudice_id()));

create policy ref_select on referti for select to authenticated
  using (is_comitato() or exists (select 1 from convocazioni c where c.id = convocazione_id and c.giudice_id = my_giudice_id()));
create policy ref_insert on referti for insert to authenticated
  with check (is_comitato() or exists (select 1 from convocazioni c where c.id = convocazione_id and c.giudice_id = my_giudice_id()));
create policy ref_delete on referti for delete to authenticated using (is_comitato());

-- parametri e log: lettura a tutti, scrittura comitato
create policy par_select on parametri for select to authenticated using (true);
create policy par_write  on parametri for all    to authenticated using (is_comitato()) with check (is_comitato());
create policy log_select on sync_log  for select to authenticated using (true);
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
