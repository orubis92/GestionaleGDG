// =====================================================================
//  GestionaleGDG — Edge Function "sync"
//  Sincronizza il calendario gare (arco.swen) e l'albo giudici (Albo Nazionale CSAIN).
//  Chiamata dall'app con: supabase.functions.invoke('sync', { body: { tipo: 'swen' | 'albo' } })
//  Richiede un utente loggato con ruolo "comitato".
//
//  Pubblicazione:  supabase functions deploy sync --no-verify-jwt=false
//  (vedi README.md nella root del repository)
// =====================================================================

import { createClient } from "npm:@supabase/supabase-js@2";

const SWEN_URL = "https://arco-api.swen.it/api/eventiview/public";
const ALBO_URL = "https://apigtweb.csain.eu/v1/albo";
const ALBO_FILTRO = { Cognome: "", Nome: "", IDSport: 95, IDDisciplinaSportiva: 349, Qualifica: "UDG", SottoQualifica: null, SiglaProvincia: "" };

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
  return { messaggio: `Calendario arco.swen: ${gare.length} gare lette`, inseriti, aggiornati, segnalati: 0, note: note.slice(0, 50) };
}

// ---------------------------------------------------------------------
// Albo giudici — Albo Nazionale CSAIN
// ---------------------------------------------------------------------
async function syncAlbo(db: ReturnType<typeof createClient>) {
  const r = await fetch(ALBO_URL, { method: "POST", headers: { "Content-Type": "application/json", Accept: "application/json" }, body: JSON.stringify(ALBO_FILTRO) });
  if (!r.ok) throw new Error(`Albo Nazionale ha risposto ${r.status}`);
  const body = await r.json();
  const albo = (body?.data ?? []) as Record<string, unknown>[];
  if (!Array.isArray(albo)) throw new Error("Risposta Albo non valida");

  const { data: esistenti, error } = await db.from("giudici").select("id, albo_id, cognome, nome, provincia, presente_in_albo");
  if (error) throw error;
  type GiudiceRow = { id: string; albo_id: string | null; cognome: string; nome: string; provincia: string | null; presente_in_albo: boolean | null };
  const rows = (esistenti ?? []) as GiudiceRow[];
  const byAlbo = new Map<string, GiudiceRow>(rows.filter((g) => g.albo_id).map((g) => [String(g.albo_id), g]));
  const byNome = new Map<string, GiudiceRow>(rows.map((g) => [`${g.cognome} ${g.nome}`.toLowerCase().replace(/\s+/g, " "), g]));

  let inseriti = 0, aggiornati = 0, segnalati = 0; const note: string[] = [];
  const visti = new Set<string>();
  const now = new Date().toISOString();

  for (const a of albo) {
    const alboId = String(a.ID);
    const cognome = capWords(a.Cognome as string), nome = capWords(a.Nome as string);
    visti.add(alboId);
    let ex = byAlbo.get(alboId);
    if (!ex) {
      // giudice inserito a mano con lo stesso nome? collegalo all'albo
      const m = byNome.get(`${cognome} ${nome}`.toLowerCase());
      if (m && !m.albo_id) { ex = m; note.push(`Collegato all'albo: ${cognome} ${nome}`); }
    }
    if (!ex) {
      const { error: ie } = await db.from("giudici").insert({ albo_id: alboId, cognome, nome, sesso: (a.Sesso as string) || null, provincia: (a.SiglaProvincia as string) || null, origine: "albo", presente_in_albo: true, ultima_sync_albo: now, qualifica: "regionale", attivo: true, note: "Importato dall'Albo Nazionale: verificare qualifica e contatti" });
      if (ie) { note.push(`Errore inserimento ${cognome} ${nome}: ${ie.message}`); continue; }
      inseriti++;
    } else {
      const upd: Record<string, unknown> = { albo_id: alboId, presente_in_albo: true, ultima_sync_albo: now };
      if (!ex.provincia && a.SiglaProvincia) upd.provincia = a.SiglaProvincia;
      const { error: ue } = await db.from("giudici").update(upd).eq("id", ex.id);
      if (ue) { note.push(`Errore aggiornamento ${cognome} ${nome}: ${ue.message}`); continue; }
      if (ex.presente_in_albo !== true) aggiornati++;
    }
  }
  // chi era in albo e non c'è più: segnala (non cancella, non disattiva)
  for (const g of rows) {
    if (g.albo_id && !visti.has(String(g.albo_id)) && g.presente_in_albo !== false) {
      await db.from("giudici").update({ presente_in_albo: false, ultima_sync_albo: now }).eq("id", g.id);
      segnalati++; note.push(`Non più presente nell'albo: ${g.cognome} ${g.nome}`);
    }
  }
  return { messaggio: `Albo Nazionale: ${albo.length} ufficiali di gara letti`, inseriti, aggiornati, segnalati, note: note.slice(0, 50) };
}
