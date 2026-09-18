// Finto client Supabase in memoria per test UI
(function(){
  const uid=(p)=>p+'-'+Math.random().toString(36).slice(2,10);
  const T={
    giudici:[
      {id:'g1',cognome:'Verdi',nome:'Anna',email:'comitato@test.it',qualifica:'nazionale',attivo:true,in_affiancamento:false,affiancamenti_richiesti:2,provincia:'CR',regione:'Lombardia',comune:'Cremona',societa:'Arcieri Cremona',scadenza_tessera:'2027-01-31',scadenza_certificato:'2026-10-01',data_nascita:'1980-05-05',origine:'manuale'},
      {id:'g2',cognome:'Rossi',nome:'Mario',email:'rossi@test.it',qualifica:'regionale',attivo:true,in_affiancamento:false,affiancamenti_richiesti:2,provincia:'BG',regione:'Lombardia',comune:'Bergamo',societa:'Branco Arcieri del Lupo',scadenza_tessera:'2026-01-31',origine:'albo',albo_id:'9728',swen_id:107,tessera_numero:'2',tessera_tipo:'QUADRI COPERTURA RCT',presente_in_albo:true},
      {id:'g3',cognome:'Bianchi',nome:'Luca',email:'nuovo@test.it',qualifica:'regionale',attivo:true,in_affiancamento:true,affiancamenti_richiesti:2,provincia:'MI',regione:'Lombardia',origine:'manuale'},
      {id:'g4',cognome:'Neri',nome:'Paola',qualifica:'emerito',attivo:false,in_affiancamento:false,affiancamenti_richiesti:2,origine:'albo',presente_in_albo:false}
    ],
    gare:[
      {id:'ga1',swen_id:1,titolo:'Trofeo Nazionale 60 Track',data_inizio:'2026-10-04',anno_sportivo:'2026/2027',classificazione:'Nazionale',tipo_codice:'60_TRACK',tipo_descrizione:'60 Track',societa_organizzatrice:'Arcieri Cremona',comune:'Cremona',provincia:'CR',regione:'Lombardia',numero_percorsi:2,fabbisogno_giudici:2,stato:'programmata',origine:'swen',giudice_swen:'VERDI ANNA',indoor:false},
      {id:'ga2',swen_id:2,titolo:'Gara Regionale 40 Round',data_inizio:'2026-10-11',anno_sportivo:'2026/2027',classificazione:'Regionale',tipo_codice:'40_ROUND',tipo_descrizione:'40 Round',societa_organizzatrice:'Branco Arcieri del Lupo',comune:'Alzano Lombardo',provincia:'BG',regione:'Lombardia',numero_percorsi:1,fabbisogno_giudici:1,stato:'programmata',origine:'swen',giudice_swen:'ROSSI MARIO',indoor:false},
      {id:'ga3',titolo:'Gara passata 44 Fusion',data_inizio:'2026-09-06',anno_sportivo:'2026/2027',classificazione:'Regionale',tipo_descrizione:'44 Fusion',societa_organizzatrice:'ASD Test',comune:'Lodi',provincia:'LO',regione:'Lombardia',numero_percorsi:1,fabbisogno_giudici:1,stato:'programmata',origine:'manuale',indoor:false},
      {id:'ga4',swen_id:4,titolo:'Gara svolta anno scorso',data_inizio:'2026-03-15',anno_sportivo:'2025/2026',classificazione:'Regionale',tipo_descrizione:'40 Round',societa_organizzatrice:'ASD Test',regione:'Toscana',numero_percorsi:1,fabbisogno_giudici:1,stato:'svolta',origine:'swen',giudice_swen:'BIANCHI LUCA',indoor:false}
    ],
    profili:[{id:'u1',email:'comitato@test.it',ruolo:'comitato',giudice_id:'g1'},{id:'u2',email:'rossi@test.it',ruolo:'giudice',giudice_id:'g2'},{id:'u3',email:'nuovo@test.it',ruolo:'ospite',giudice_id:null}],
    disponibilita:[{id:'d1',gara_id:'ga1',giudice_id:'g2',stato:'disponibile',note:'solo come affiancamento'},{id:'d3',gara_id:'ga2',giudice_id:'g1',stato:'disponibile'},{id:'d2',gara_id:'ga2',giudice_id:'g3',stato:'non_disponibile'}],
    convocazioni:[
      {id:'c1',gara_id:'ga1',giudice_id:'g1',ruolo:'coordinatore',stato:'confermata',deroga:false},
      {id:'c2',gara_id:'ga2',giudice_id:'g2',ruolo:'giudice',stato:'proposta',deroga:false},
      {id:'c3',gara_id:'ga3',giudice_id:'g2',ruolo:'giudice',stato:'confermata',deroga:false},
      {id:'c4',gara_id:'ga4',giudice_id:'g3',ruolo:'affiancamento',stato:'svolta',deroga:false},
      {id:'c5',gara_id:'ga4',giudice_id:'g2',ruolo:'giudice',stato:'svolta',deroga:false}
    ],
    convocazioni_storico:[], aggiornamenti:[{id:'a1',giudice_id:'g1',data:'2026-02-01',descrizione:'Aggiornamento GdG 2026',ore:4}],
    rimborsi:[{id:'r1',convocazione_id:'c5',modalita:'km_spese',km:80,tariffa_km:0.25,gettone:0,spese:[{descrizione:'pedaggio',importo:5}],totale:25,stato:'compilato'}],
    referti:[{id:'f1',convocazione_id:'c4',storage_path:'c4/x.pdf',nome_file:'referto.pdf',created_at:'2026-03-16T10:00:00Z'}],
    parametri:[{anno_sportivo:'2026/2027',tariffa_km:0.25,gettone_regionale:20,gettone_nazionale:40,gettone_coordinatore:60,modalita_default:'km_spese',min_servizi_12m:1,min_aggiornamenti_12m:1,mesi_inattivita_max:24,eta_min:18,eta_max:75}],
    sync_log:[],
    corsi:[{id:'k1',titolo:'Aggiornamento annuale GdG 2026/2027',tipo:'aggiornamento',data:'2026-11-08',ore:4,luogo:'Cremona',obbligatorio:true,stato:'programmato'},{id:'k2',titolo:'Riunione tecnica indoor',tipo:'riunione',data:'2026-09-05',ore:2,luogo:'online',obbligatorio:false,stato:'svolto'}],
    corsi_presenze:[{id:'p1',corso_id:'k1',giudice_id:'g1',stato:'partecipa'},{id:'p2',corso_id:'k1',giudice_id:'g2',stato:'invitato'},{id:'p3',corso_id:'k1',giudice_id:'g3',stato:'non_partecipa'},{id:'p4',corso_id:'k2',giudice_id:'g1',stato:'presente'},{id:'p5',corso_id:'k2',giudice_id:'g2',stato:'assente'}]
  };
  function view(name){
    if(name==='v_convocazioni') return T.convocazioni.map(c=>{ const g=T.giudici.find(x=>x.id===c.giudice_id)||{}, ga=T.gare.find(x=>x.id===c.gara_id)||{}, r=T.rimborsi.find(x=>x.convocazione_id===c.id);
      return {...c, cognome:g.cognome,nome:g.nome,qualifica:g.qualifica,in_affiancamento:g.in_affiancamento,titolo:ga.titolo,data_inizio:ga.data_inizio,data_fine:ga.data_fine,anno_sportivo:ga.anno_sportivo,tipo_codice:ga.tipo_codice,tipo_descrizione:ga.tipo_descrizione,classificazione:ga.classificazione,gara_regione:ga.regione,gara_provincia:ga.provincia,societa_organizzatrice:ga.societa_organizzatrice,giudice_swen:ga.giudice_swen,gara_stato:ga.stato,rimborso_totale:r?r.totale:null,rimborso_stato:r?r.stato:null,referto_caricato:T.referti.some(f=>f.convocazione_id===c.id)}; });
    if(name==='v_stato_giudici') return T.giudici.map(g=>{ const sv=T.convocazioni.filter(c=>c.giudice_id===g.id&&c.stato==='svolta'); return {id:g.id,cognome:g.cognome,nome:g.nome,qualifica:g.qualifica,in_affiancamento:g.in_affiancamento,attivo:g.attivo,servizi_12m:sv.length,aggiornamenti_12m:T.aggiornamenti.filter(a=>a.giudice_id===g.id).length,ultimo_servizio:sv.length?'2026-03-15':null,affiancamenti_svolti:sv.filter(c=>c.ruolo==='affiancamento').length,affiancamenti_richiesti:g.affiancamenti_richiesti,scadenza_tessera:g.scadenza_tessera,scadenza_certificato:g.scadenza_certificato,eta:g.data_nascita?46:null,tessera_scaduta:!!(g.scadenza_tessera&&g.scadenza_tessera<'2026-09-17'),certificato_scaduto:false}; });
    return T[name];
  }
  function q(table){
    const st={filters:[],op:'select',payload:null,single:false,maybe:false,order:null};
    const run=()=>{
      let rows=(view(table)||[]).slice();
      st.filters.forEach(f=>{ if(f.t==='eq') rows=rows.filter(r=>r[f.k]===f.v); if(f.t==='in') rows=rows.filter(r=>f.v.includes(r[f.k])); if(f.t==='not') rows=rows.filter(r=>r[f.k]!=null); });
      if(st.op==='insert'){ const recs=(Array.isArray(st.payload)?st.payload:[st.payload]).map(r=>({id:uid(table),created_at:new Date().toISOString(),...r})); T[table].push(...recs); rows=recs; }
      if(st.op==='update'){ rows.forEach(r=>{ const t=T[table].find(x=>x.id===r.id); Object.assign(t,st.payload); }); }
      if(st.op==='upsert'){ const key=table==='parametri'?'anno_sportivo':'id'; const t=T[table].find(x=>x[key]===st.payload[key]); if(t) Object.assign(t,st.payload); else T[table].push(st.payload); rows=[st.payload]; }
      if(st.op==='delete'){ const ids=new Set(rows.map(r=>r.id)); T[table]=T[table].filter(r=>!ids.has(r.id)); }
      if(st.order) rows.sort((a,b)=>(a[st.order.k]>b[st.order.k]?1:-1)*(st.order.asc?1:-1));
      let data=rows; if(st.single||st.maybe) data=rows[0]||null;
      return Promise.resolve({data, error:null});
    };
    const b={
      select(){ return b; }, eq(k,v){ st.filters.push({t:'eq',k,v}); return b; }, in(k,v){ st.filters.push({t:'in',k,v}); return b; }, not(k){ st.filters.push({t:'not',k}); return b; },
      order(k,o){ st.order={k,asc:!o||o.ascending!==false}; return b; }, limit(){ return b; },
      insert(p){ st.op='insert'; st.payload=p; return b; }, update(p){ st.op='update'; st.payload=p; return b; }, upsert(p){ st.op='upsert'; st.payload=p; return b; }, delete(){ st.op='delete'; return b; },
      single(){ st.single=true; return b; }, maybeSingle(){ st.maybe=true; return b; },
      then(res,rej){ return run().then(res,rej); }
    };
    return b;
  }
  const users={'comitato@test.it':{id:'u1',email:'comitato@test.it'},'rossi@test.it':{id:'u2',email:'rossi@test.it'},'nuovo@test.it':{id:'u3',email:'nuovo@test.it'}};
  let session=null;
  window.supabase={ createClient(){ return {
    auth:{ getSession:async()=>({data:{session}}), onAuthStateChange(){}, signInWithPassword:async({email})=>{ const u=users[email]; if(!u) return {error:{message:'Invalid login credentials'}}; session={user:u}; return {data:{user:u},error:null}; }, signUp:async({email})=>({data:{user:{id:'u9',email},session:null},error:null}), resetPasswordForEmail:async()=>({error:null}), signOut:async()=>{session=null;}, updateUser:async()=>({error:null}) },
    from:q,
    rpc:async(name,args)=>{ if(name==='invita_tutti'){ const n=T.giudici.filter(g=>g.attivo&&!T.corsi_presenze.some(p=>p.corso_id===args.p_corso&&p.giudice_id===g.id)).length; T.giudici.filter(g=>g.attivo).forEach(g=>{ if(!T.corsi_presenze.some(p=>p.corso_id===args.p_corso&&p.giudice_id===g.id)) T.corsi_presenze.push({id:uid('p'),corso_id:args.p_corso,giudice_id:g.id,stato:'invitato'}); }); return {data:n,error:null}; } return {data:{convocazioni_create:1,confermate:0,svolte:1,gare_chiuse:0,future_senza_convocazione:1,chiuse_automaticamente:[],errori:['06/09/2026 Gara affiancato solo — BIANCHI LUCA: art. 2']},error:null}; },
    storage:{ from(){ return { upload:async()=>({error:null}), download:async()=>({data:new Blob(['x']),error:null}), remove:async()=>({error:null}) }; } },
    functions:{ invoke:async(name,{body})=>({data:{messaggio:'Mock '+body.tipo,inseriti:3,aggiornati:1,segnalati:0,note:['nota di prova']},error:null}) }
  }; } };
  window.__T=T;
})();
