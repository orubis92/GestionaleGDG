// =====================================================================
//  GestionaleGDG — Edge Function "notifica"
//  Invia una notifica (push Web Push + email) per una riga della tabella "notifiche".
//  Viene chiamata da un Database Webhook su INSERT in "notifiche" (payload Supabase
//  {type:'INSERT', table:'notifiche', record:{...}}), oppure a mano con {id:'<uuid>'}.
//
//  Segreti richiesti (Edge Functions → Secrets):
//    VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (es. mailto:comitato@esempio.it)
//  Opzionali per l'email (uno dei due):
//    BREVO_API_KEY  + EMAIL_FROM (mittente verificato su Brevo)   oppure
//    RESEND_API_KEY + EMAIL_FROM (dominio verificato su Resend)
//    APP_URL (default https://orubis92.github.io/GestionaleGDG/)
// =====================================================================

import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const url = Deno.env.get("SUPABASE_URL")!, service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const db = createClient(url, service);

  // Accetta: (a) la chiave service_role del progetto (formato legacy JWT "eyJ…" o nuova "sb_secret_…"),
  // passata come "Authorization: Bearer <chiave>" o come header "apikey"; (b) un utente loggato con ruolo comitato (invio di prova).
  const rawAuth = req.headers.get("Authorization") ?? "";
  const token = rawAuth.trim().split(/\s+/).pop() ?? "";            // tollera "Bearer", "bearer", refusi nel prefisso, nessun prefisso
  const apikey = (req.headers.get("apikey") ?? "").trim();
  const isServiceKey = (t: string) => {
    if (!t) return false;
    if (t === service) return true;
    if (t.startsWith("sb_secret_")) return true;                     // nuove secret key: le possiede solo il proprietario del progetto
    try { const payload = JSON.parse(atob(t.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))); return payload?.role === "service_role"; } catch { return false; }
  };
  let autorizzato = isServiceKey(token) || isServiceKey(apikey);
  if (!autorizzato && token) {
    const uc = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: `Bearer ${token}` } } });
    const { data: { user } } = await uc.auth.getUser();
    if (user) { const { data: p } = await uc.from("profili").select("ruolo").eq("id", user.id).maybeSingle(); autorizzato = p?.ruolo === "comitato"; }
  }
  if (!autorizzato) return json({ error: "Non autorizzato", dettaglio: `header Authorization ${rawAuth ? "presente (" + rawAuth.slice(0, 12) + "…)" : "assente"}, apikey ${apikey ? "presente" : "assente"}` }, 401);

  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* vuoto */ }
  const record = (body.record as Record<string, unknown>) ?? null;
  const id = (record?.id as string) ?? (body.id as string);
  if (!id) return json({ error: "Manca l'id della notifica" }, 400);

  const { data: n, error } = await db.from("notifiche").select("*").eq("id", id).maybeSingle();
  if (error || !n) return json({ error: error?.message ?? "Notifica non trovata" }, 404);

  const { data: pref } = await db.from("notifiche_preferenze").select("*").eq("user_id", n.user_id).maybeSingle();
  const eventi = (pref?.eventi as Record<string, boolean>) ?? {};
  const tipoOk = eventi[n.tipo] !== false;                    // di default tutto attivo
  const vuolePush = tipoOk && (pref?.push ?? true);
  const vuoleEmail = tipoOk && (pref?.email ?? false);
  const appUrl = Deno.env.get("APP_URL") ?? "https://orubis92.github.io/GestionaleGDG/";
  const esito: Record<string, unknown> = { id, push: 0, push_errori: 0, email: false };

  // ---- PUSH ----
  if (vuolePush) {
    const pub = Deno.env.get("VAPID_PUBLIC_KEY"), priv = Deno.env.get("VAPID_PRIVATE_KEY"), subj = Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@example.com";
    if (pub && priv) {
      webpush.setVapidDetails(subj, pub, priv);
      const { data: subs } = await db.from("push_iscrizioni").select("*").eq("user_id", n.user_id);
      const payload = JSON.stringify({ title: n.titolo, body: n.corpo ?? "", url: appUrl, dati: n.dati ?? {}, id: n.id, tipo: n.tipo });
      for (const s of subs ?? []) {
        try {
          await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 60 * 60 * 24 });
          (esito.push as number)++;
          await db.from("push_iscrizioni").update({ ultimo_uso: new Date().toISOString() }).eq("id", s.id);
        } catch (e) {
          const code = (e as { statusCode?: number }).statusCode;
          (esito.push_errori as number)++;
          if (code === 404 || code === 410) await db.from("push_iscrizioni").delete().eq("id", s.id);   // iscrizione scaduta
        }
      }
    } else esito.push = "VAPID non configurato";
  }

  // ---- EMAIL ----
  if (vuoleEmail) {
    const { data: prof } = await db.from("profili").select("email").eq("id", n.user_id).maybeSingle();
    const to = prof?.email as string | undefined;
    const from = Deno.env.get("EMAIL_FROM");
    const brevo = Deno.env.get("BREVO_API_KEY"), resend = Deno.env.get("RESEND_API_KEY");
    if (to && from && (brevo || resend)) {
      const html = `<p style="font:15px/1.5 -apple-system,Segoe UI,Roboto,sans-serif"><b>${esc(n.titolo)}</b><br>${esc(n.corpo ?? "")}</p><p style="font:14px sans-serif"><a href="${appUrl}">Apri GestionaleGDG</a></p><p style="font:12px sans-serif;color:#888">Comitato Giudici di Gara CSAIn · per non ricevere più queste email disattiva "Email" nel tuo profilo nell'app.</p>`;
      try {
        let r: Response;
        if (brevo) {
          r = await fetch("https://api.brevo.com/v3/smtp/email", { method: "POST", headers: { "api-key": brevo, "Content-Type": "application/json" },
            body: JSON.stringify({ sender: { email: from, name: "GestionaleGDG" }, to: [{ email: to }], subject: `[GdG] ${n.titolo}`, htmlContent: html }) });
        } else {
          r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: `Bearer ${resend}`, "Content-Type": "application/json" },
            body: JSON.stringify({ from: `GestionaleGDG <${from}>`, to: [to], subject: `[GdG] ${n.titolo}`, html }) });
        }
        esito.email = r.ok ? true : `errore ${r.status}: ${(await r.text()).slice(0, 200)}`;
      } catch (e) { esito.email = `errore: ${(e as Error).message}`; }
    } else esito.email = "email non configurata o destinatario mancante";
  }

  await db.from("notifiche").update({ inviata_push: vuolePush ? (esito.push as number) > 0 : null, inviata_email: vuoleEmail ? esito.email === true : null }).eq("id", id);
  return json(esito);
});

function esc(s: string) { return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c] as string)); }
