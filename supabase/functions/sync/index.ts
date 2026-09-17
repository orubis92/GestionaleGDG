// =====================================================================
//  GestionaleGDG — Edge Function "sync"
//  Sincronizza il calendario gare e l'albo giudici di gara, entrambi dal portale arco.swen,
//  poi riconcilia le convocazioni con il giudice registrato sul portale (funzione SQL riconcilia_swen).
//  Chiamata dall'app con: supabase.functions.invoke('sync', { body: { tipo: 'swen' | 'albo' } })
//  Richiede un utente loggato con ruolo "comitato".
//
//  Pubblicazione:  supabase functions deploy sync --no-verify-jwt=false
//  (vedi README.md nella root del repository)
// =====================================================================

import { createClient } from "npm:@supabase/supabase-js@2";

const SWEN_URL = "https://arco-api.swen.it/api/eventiview/public";
const ALBO_URL = "https://arco-api.swen.it/api/albo";   // albo tecnici/istruttori del portale arco.swen (pubblico)

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const capWords = (s: string) =>
  (s || "").toLowerCase().replace(/(^|[\s'’-])(\S)/g, (_m, p, c) => p + c.toUpperCase()).trim();
const annoSportivo = (iso: string) => {
  const d = new Date(iso); const y = d.getFullYear();
  return d.getMonth() >= 8 ? `${y}/${y + 1}` : `${y - 1}/${y}`;
};
const soloData = (iso: string | null) => (iso ? iso.slice(0, 10) : null);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const url = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // 1. Verifica che chi chiama sia un membro del comitato
  const auth = req.headers.get("Authorization") ?? "";
  const userClient = createClient(url, anon, { global: { headers: { Authorization: auth } } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "Non autenticato" }, 401);
  const { data: prof } = await userClient.from("profili").select("ruolo").eq("id", user.id).maybeSingle();
  if (!prof || prof.ruolo !== "comitato") return json({ error: "Operazione riservata al comitato" }, 403);

  // 2. Client amministrativo per scrivere (bypassa RLS; i trigger trattano auth.uid() nullo come comitato)
  const db = createClient(url, service);
  let tipo = "swen";
  try { tipo = (await req.json())?.tipo ?? "swen"; } catch { /* body vuoto */ }

  try {
    const res = tipo === "albo" ? await syncAlbo(db) : await syncSwen(db);
    await db.from("sync_log").insert({ tipo, esito: "ok", inseriti: res.inseriti, aggiornati: res.aggiornati, segnalati: res.segnalati, dettagli: { note: res.note } });
    return json(res);
  } catch (e) {
    const msg = (e as Error).message ?? String(e);
    await db.from("sync_log").insert({ tipo, esito: "errore", dettagli: { errore: msg } });
    return json({ error: msg }, 500);
  }
});

// ---------------------------------------------------------------------
// Calendario gare — arco.swen
// ---------------------------------------------------------------------
async function syncSwen(db: ReturnType<typeof createClient>) {
  const r = await fetch(SWEN_URL, { headers: { Accept: "application/json" } });
  if (!r.ok) throw new Error(`arco.swen ha risposto ${r.status}`);
  const eventi = await r.json() as Record<string, unknown>[];
  if (!Array.isArray(eventi)) throw new Error("Risposta arco.swen non valida");

  const gare = eventi.filter((e) => e.TipologiaEvento === "Gara" && e.DataEvento);
  const { data: esistenti, error } = await db.from("gare").select("id, swen_id, swen_updated_at, stato, data_inizio").not("swen_id", "is", null);
  if (error) throw error;
  type GaraRow = { id: string; swen_id: number; swen_updated_at: string | null; stato: string; data_inizio: string };
  const byId = new Map<number, GaraRow>((esistenti ?? []).map((g: GaraRow) => [g.swen_id, g]));

  let inseriti = 0, aggiornati = 0; const note: string[] = [];
  const oggi = new Date().toISOString().slice(0, 10);
  const nuove: Record<string, unknown>[] = [];
  const daAggiornare: Record<string, unknown>[] = [];

  for (const e of gare) {
    const dataInizio = soloData(e.DataEvento as string)!;
    const rec = {
      swen_id: e.id as number,
      titolo: (e.TitoloEvento as string) || (e.DescrizioneEvento as string) || "Gara",
      descrizione: (e.DescrizioneEvento as string) || null,
      data_inizio: dataInizio,
      anno_sportivo: (e.AnnoSportivoDescrizione as string) || annoSportivo(dataInizio),
      societa_organizzatrice: (e.AssociazioneDenominazione as string) || null,
      societa_codice: (e.AssociazioneCodice as string) || null,
      regione: (e.SezioneDescrizione as string) || null,
      provincia: (e.ProvinciaIndirizzo as string) || null,
      comune: e.CittaIndirizzo ? capWords(e.CittaIndirizzo as string) : null,
      indirizzo: (e.Indirizzo as string) || null,
      cap: (e.Cap as string) || null,
      coordinate_gps: (e.CoordinateGPS as string) || null,
      email_riferimento: (e.EmailRiferimento as string) || null,
      tipo_codice: (e.TipoEventoCodice as string) || null,
      tipo_descrizione: (e.TipoEventoDescrizione as string) || null,
      classificazione: (e.ClassificazioneEvento as string) || null,
      indoor: !!e.isIndoor || /indoor/i.test((e.TipoEventoCodice as string) || ""),
      origine: "swen",
      giudice_swen: (e.Giudice as string) || null,
      swen_stato: (e.StatoEvento as string) || null,
      swen_partecipanti: e.TotalePartecipanti ? Number(e.TotalePartecipanti) : null,
      swen_updated_at: (e.updatedAt as string) || null,
      ultima_sync: new Date().toISOString(),
    };
    const ex = byId.get(rec.swen_id);
    if (!ex) {
      // gara nuova: stato in base a data e flag attivo
      const stato = e.isAttivo === false ? "annullata" : (dataInizio < oggi ? "svolta" : "programmata");
      nuove.push({ ...rec, stato, numero_percorsi: 1, fabbisogno_giudici: 1 });
    } else {
      // gara esistente: si riallineano solo i campi di arco.swen (non stato/percorsi/fabbisogno/note del comitato)
      const upd: Record<string, unknown> = { ...rec };
      if (e.isAttivo === false && ex.stato !== "annullata") { upd.stato = "annullata"; note.push(`Annullata su arco.swen: ${rec.titolo} (${dataInizio})`); }
      if (ex.swen_updated_at !== rec.swen_updated_at || ex.data_inizio !== dataInizio || upd.stato) { daAggiornare.push(upd); }
    }
  }
  // scritture a blocchi: upsert su swen_id aggiorna solo le colonne presenti nell'oggetto
  for (let i = 0; i < nuove.length; i += 200) {
    const blocco = nuove.slice(i, i + 200);
    const { error: ie } = await db.from("gare").insert(blocco);
    if (ie) { note.push(`Errore inserimento blocco ${i / 200 + 1}: ${ie.message}`); continue; }
    inseriti += blocco.length;
  }
  for (let i = 0; i < daAggiornare.length; i += 200) {
    const blocco = daAggiornare.slice(i, i + 200);
    const { error: ue } = await db.from("gare").upsert(blocco, { onConflict: "swen_id" });
    if (ue) { note.push(`Errore aggiornamento blocco ${i / 200 + 1}: ${ue.message}`); continue; }
    aggiornati += blocco.length;
  }
  // riconciliazione automatica: convocazioni dal campo "Giudice" del portale, chiusura gare passate
  const { data: ric, error: re } = await db.rpc("riconcilia_swen");
  if (re) note.push(`Riconciliazione non eseguita: ${re.message}`);
  else {
    note.unshift(`Riconciliazione: ${ric.convocazioni_create} convocazioni create, ${ric.confermate} confermate, ${ric.svolte} chiuse come svolte, ${ric.gare_chiuse} gare passate chiuse`);
    for (const e of (ric.errori ?? []) as string[]) note.push(`Non riconciliata: ${e}`);
  }
  return { messaggio: `Calendario arco.swen: ${gare.length} gare lette`, inseriti, aggiornati, segnalati: ((ric?.errori ?? []) as string[]).length, note: note.slice(0, 60) };
}

// ---------------------------------------------------------------------
// Albo giudici di gara — portale arco.swen (/api/albo, campo AbilitazioneTecnico = "GIUDICE DI GARA")
// ---------------------------------------------------------------------
async function syncAlbo(db: ReturnType<typeof createClient>) {
  const r = await fetch(ALBO_URL, { headers: { Accept: "application/json" } });
  if (!r.ok) throw new Error(`Albo arco.swen ha risposto ${r.status}`);
  const tutti = await r.json() as Record<string, unknown>[];
  if (!Array.isArray(tutti)) throw new Error("Risposta albo non valida");
  const albo = tutti.filter((a) => /GIUDICE/i.test(String(a.AbilitazioneTecnico ?? "")));

  const { data: esistenti, error } = await db.from("giudici").select("id, swen_id, albo_id, cognome, nome, provincia, regione, comune, societa, societa_codice, sesso, tessera_numero, tessera_tipo, presente_in_albo, attivo");
  if (error) throw error;
  type GiudiceRow = { id: string; swen_id: number | null; albo_id: string | null; cognome: string; nome: string; provincia: string | null; regione: string | null; comune: string | null; societa: string | null; societa_codice: string | null; sesso: string | null; tessera_numero: string | null; tessera_tipo: string | null; presente_in_albo: boolean | null; attivo: boolean };
  const rows = (esistenti ?? []) as GiudiceRow[];
  const norm = (t: string) => (t || "").toUpperCase().replace(/\s+/g, " ").trim();
  const bySwen = new Map<number, GiudiceRow>(rows.filter((g) => g.swen_id != null).map((g) => [g.swen_id as number, g]));
  const byNome = new Map<string, GiudiceRow>(rows.map((g) => [norm(`${g.cognome} ${g.nome}`), g]));

  let inseriti = 0, aggiornati = 0, segnalati = 0; const note: string[] = [];
  const visti = new Set<number>();
  const now = new Date().toISOString();

  for (const a of albo) {
    const swenId = Number(a.id);
    const cognome = capWords(String(a.Cognome ?? "")).trim(), nome = capWords(String(a.Nome ?? "")).replace(/\s+/g, " ").trim();
    if (!cognome || !nome) continue;
    visti.add(swenId);
    // dati anagrafici forniti dal portale (mai il codice fiscale)
    const dati: Record<string, unknown> = {
      swen_id: swenId, presente_in_albo: a.isAttivo !== false, ultima_sync_albo: now,
      sesso: a.Sesso === "F" ? "F" : a.Sesso === "M" ? "M" : null,
      provincia: (a.Provincia as string) || null,
      regione: (a.SezioneDescrizione as string) || null,
      comune: a.Citta ? capWords(String(a.Citta)) : null,
      societa: (a.AssociazioneDenominazione as string) || null,
      societa_codice: (a.AssociazioneCodice as string) || null,
      tessera_numero: (a.NumeroTesseraTecnico as string) || null,
      tessera_tipo: (a.TipoTesseraTecnico as string) || null,
    };
    let ex = bySwen.get(swenId) ?? byNome.get(norm(`${cognome} ${nome}`)) ?? byNome.get(norm(`${nome} ${cognome}`));
    if (!ex) {
      const { error: ie } = await db.from("giudici").insert({ ...dati, cognome, nome, origine: "albo", qualifica: "regionale", attivo: true, note: "Importato dall'albo arco.swen: verificare qualifica e contatti" });
      if (ie) { note.push(`Errore inserimento ${cognome} ${nome}: ${ie.message}`); continue; }
      inseriti++; note.push(`Nuovo: ${cognome} ${nome} (${dati.provincia ?? "-"})`);
    } else {
      // aggiorna solo i campi vuoti o gestiti dal portale; non tocca contatti, qualifica, scadenze, note
      const upd: Record<string, unknown> = { swen_id: swenId, presente_in_albo: dati.presente_in_albo, ultima_sync_albo: now, tessera_numero: dati.tessera_numero, tessera_tipo: dati.tessera_tipo, societa: dati.societa, societa_codice: dati.societa_codice };
      for (const k of ["sesso", "provincia", "regione", "comune"]) if (!(ex as Record<string, unknown>)[k] && dati[k]) upd[k] = dati[k];
      const { error: ue } = await db.from("giudici").update(upd).eq("id", ex.id);
      if (ue) { note.push(`Errore aggiornamento ${cognome} ${nome}: ${ue.message}`); continue; }
      if (ex.swen_id !== swenId || ex.presente_in_albo !== true || ex.tessera_numero !== dati.tessera_numero || ex.societa !== dati.societa) aggiornati++;
    }
  }
  // chi era collegato all'albo e non c'è più: segnala (non cancella, non disattiva)
  for (const g of rows) {
    if (g.swen_id != null && !visti.has(g.swen_id) && g.presente_in_albo !== false) {
      await db.from("giudici").update({ presente_in_albo: false, ultima_sync_albo: now }).eq("id", g.id);
      segnalati++; note.push(`Non più presente nell'albo: ${g.cognome} ${g.nome}`);
    }
  }
  return { messaggio: `Albo arco.swen: ${albo.length} giudici di gara letti (su ${tutti.length} tecnici/istruttori)`, inseriti, aggiornati, segnalati, note: note.slice(0, 60) };
}
