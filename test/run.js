const { chromium } = require('playwright');
const fs = require('fs'); const path = require('path');
const APP = require('path').join(__dirname,'..');
  // serve l'app dalla cartella del repository
  const http=require('http'); const srv=http.createServer((rq,rs)=>{ const f=path.join(APP, decodeURIComponent(rq.url.split('?')[0]).replace(/^\//,'')||'index.html'); fs.readFile(f,(e,d)=>{ if(e){rs.statusCode=404;return rs.end();} rs.setHeader('Content-Type', f.endsWith('.js')?'application/javascript':f.endsWith('.json')?'application/json':f.endsWith('.png')?'image/png':'text/html'); rs.end(d); }); }).listen(8765);
(async () => {
  const browser = await chromium.launch({ executablePath: process.env.PW_CHROMIUM || undefined });
  const errors = [];
  async function newPage(){
    const ctx = await browser.newContext({ viewport:{width:1100,height:900} });
    const page = await ctx.newPage();
    page.on('pageerror', e => errors.push('PAGEERROR: ' + e.message));
    page.on('console', m => { if (m.type()==='error') errors.push('CONSOLE: ' + m.text()); });
    await page.route('**/supabase-js@2/**', r => r.fulfill({ contentType:'application/javascript', body: fs.readFileSync(__dirname+'/mock-supabase.js','utf8') }));
    await page.route('**/xlsx/**', r => r.fulfill({ contentType:'application/javascript', body: fs.readFileSync(require.resolve('xlsx/dist/xlsx.full.min.js'),'utf8') }));
    await page.route('**/*', r => { const u=r.request().url(); if(u.startsWith('http://localhost')||u.startsWith('file://')) r.continue(); else if(/supabase-js|xlsx/.test(u)) r.fallback(); else r.fulfill({status:200, body:''}); });
    await page.goto('http://localhost:8765/index.html');
    await page.evaluate(()=>localStorage.setItem('gdg_cfg', JSON.stringify({SUPABASE_URL:'https://test.supabase.co',SUPABASE_ANON_KEY:'x'.repeat(50)})));
    await page.reload();
    try{ await page.waitForSelector('#login:not(.hidden)', {timeout:5000}); }catch(e){ console.log('LOGIN NOT SHOWN', errors); throw e; }
    return page;
  }
  const shot = async (page, n) => page.screenshot({ path:`${__dirname}/shots/${n}.png`, fullPage:true });
  fs.mkdirSync(__dirname+'/shots',{recursive:true});

  // ---- COMITATO ----
  let page = await newPage();
  await page.fill('#li-email','comitato@test.it'); await page.fill('#li-pass','x'); await page.click('text=Accedi');
  await page.waitForSelector('#app:not(.hidden)'); await page.waitForTimeout(300);
  await shot(page,'01-home-comitato');
  for (const t of ['gare','giudici','rimborsi','report','impostazioni']) { await page.evaluate(k=>go(k), t); await page.waitForTimeout(150); await shot(page,'02-'+t); }
  for (const r of ['giudici','mantenimento','copertura','riconcilia','referti']) { await page.evaluate(k=>{S.filtri.report=k;go('report')}, r); await page.waitForTimeout(150); await shot(page,'03-report-'+r); }
  // modali
  await page.evaluate(()=>openGara('ga1')); await page.waitForTimeout(150); await shot(page,'04-gara');
  await page.evaluate(()=>assegnaDlg('ga1')); await page.waitForTimeout(150); await shot(page,'05-assegna');
  await page.evaluate(()=>assegnaConferma('ga1','g2')); await page.waitForTimeout(150); await shot(page,'06-assegna-conferma');
  await page.evaluate(()=>{ document.querySelector('#asg-deroga').checked=true; });
  await page.click('.modal-bg:last-child .actions >> text=Convoca'); await page.waitForTimeout(400); await shot(page,'07-dopo-convoca');
  await page.evaluate(()=>$('modals').innerHTML='');
  await page.evaluate(()=>openGiudice('g2')); await page.waitForTimeout(150); await shot(page,'08-giudice');
  await page.evaluate(()=>$('modals').innerHTML=''); await page.evaluate(()=>giudiceForm('g2')); await page.waitForTimeout(150); await shot(page,'09-giudice-form');
  await page.evaluate(()=>$('modals').innerHTML=''); await page.evaluate(()=>garaForm('ga2')); await page.waitForTimeout(150); await shot(page,'10-gara-form');
  await page.evaluate(()=>$('modals').innerHTML=''); await page.evaluate(()=>rimborsoForm('c5')); await page.waitForTimeout(300); await shot(page,'11-rimborso');
  await page.click('.modal-bg:last-child .actions >> text=Approva'); await page.waitForTimeout(300);
  await page.evaluate(()=>$('modals').innerHTML=''); await page.evaluate(()=>refertoDlg('c4')); await page.waitForTimeout(300); await shot(page,'12-referto');
  await page.evaluate(()=>$('modals').innerHTML=''); await page.evaluate(()=>parametriForm()); await page.waitForTimeout(150); await shot(page,'13-parametri');
  await page.click('.modal-bg:last-child .actions >> text=Salva'); await page.waitForTimeout(300);
  await page.evaluate(()=>$('modals').innerHTML=''); await page.evaluate(()=>profiloForm('u3')); await page.waitForTimeout(150); await shot(page,'14-profilo-form');
  await page.evaluate(()=>$('modals').innerHTML=''); await page.evaluate(()=>syncDlg('swen')); await page.waitForTimeout(150); await page.click('.modal-bg:last-child .actions >> text=Avvia'); await page.waitForTimeout(400); await shot(page,'15-sync');
  await page.evaluate(()=>$('modals').innerHTML=''); await page.evaluate(()=>openGuide()); await page.waitForTimeout(150); await shot(page,'16-guida'); await page.fill('.search','deroga'); await page.waitForTimeout(150); await shot(page,'16b-guida-ricerca'); await page.evaluate(()=>go(S.prevTab));
  await page.evaluate(()=>$('modals').innerHTML=''); await page.evaluate(()=>{S.filtri.report='riconcilia';go('report')});
  await page.evaluate(()=>cambiaStato('c3','svolta')); await page.waitForTimeout(400);
  await page.evaluate(()=>cambiaStato('c2','rifiutata')); await page.waitForTimeout(200); await page.fill('#rif-motivo','impegno di lavoro'); await page.click('.modal-bg:last-child .actions >> text=Rifiuta'); await page.waitForTimeout(400);
  await page.evaluate(()=>{S.filtri.report='giudici';go('report')}); await page.waitForTimeout(150); await shot(page,'17-report-after');
  await page.evaluate(()=>exportReport()); await page.evaluate(()=>exportRimborsi()); await page.evaluate(()=>exportGiudici()); await page.waitForTimeout(500);
  // mobile
  await page.setViewportSize({width:390,height:844}); await page.evaluate(()=>go('home')); await page.waitForTimeout(150); await shot(page,'18-mobile-home');
  await page.evaluate(()=>go('gare')); await page.waitForTimeout(150); await shot(page,'19-mobile-gare');
  await page.evaluate(()=>openGara('ga2')); await page.waitForTimeout(150); await shot(page,'20-mobile-gara');

  // ---- GIUDICE ----
  page = await newPage();
  await page.fill('#li-email','rossi@test.it'); await page.fill('#li-pass','x'); await page.click('text=Accedi');
  await page.waitForSelector('#app:not(.hidden)'); await page.waitForTimeout(300);
  await shot(page,'30-home-giudice');
  for (const t of ['gare','convocazioni','profilo']) { await page.evaluate(k=>go(k), t); await page.waitForTimeout(150); await shot(page,'31-'+t); }
  await page.evaluate(()=>setDisp('ga1','non_disponibile')); await page.waitForTimeout(300); await page.evaluate(()=>go('gare')); await shot(page,'32-disp');
  await page.evaluate(()=>rimborsoForm('c3')); await page.waitForTimeout(300); await shot(page,'33-rimborso-giudice');
  await page.evaluate(()=>$('modals').innerHTML=''); await page.evaluate(()=>giudiceForm('g2',true)); await page.waitForTimeout(150); await shot(page,'34-miei-dati');
  await page.evaluate(()=>$('modals').innerHTML=''); await page.evaluate(()=>openGara('ga1')); await page.waitForTimeout(150); await shot(page,'35-gara-giudice');

  // ---- NON COLLEGATO ----
  page = await newPage();
  await page.fill('#li-email','nuovo@test.it'); await page.fill('#li-pass','x'); await page.click('text=Accedi');
  await page.waitForSelector('#app:not(.hidden)'); await page.waitForTimeout(300); await shot(page,'40-non-collegato');
  for (const t of ['gare','convocazioni','profilo']) { await page.evaluate(k=>go(k), t); await page.waitForTimeout(100); }

  console.log('ERRORS', errors.length); errors.forEach(e=>console.log(e));
  await browser.close(); srv.close();
})();
