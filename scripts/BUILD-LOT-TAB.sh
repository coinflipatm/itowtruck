#!/usr/bin/env bash
# Rebuild dash-next/index.html (the dashboard with the PPI Lot tab) and push it.
#
# Built and browser-tested 2026-09-11. This session could not push -- the git
# proxy would not inject a credential for coinflipatm/itowtruck because the repo
# was not in that session's authorized set. Fino has since added it, so a session
# that starts WITH the repo authorized can run this and be done.
#
#   bash BUILD-LOT-TAB.sh /path/to/itowtruck
#
# It splices three fragments into dash/index.html, verifies the result against a
# pinned md5, commits and pushes. If the md5 does not match it stops and writes
# nothing -- same discipline as the 26_source_patch tool.
set -euo pipefail
REPO="${1:-/root/towos/itowtruck}"
cd "$REPO"

EXPECT_BASE=9f5250485d0f9893700454c40700bc9d   # dash/index.html this was built against
EXPECT_OUT=03aa873566a72e3f49702a5a6947bb4b    # the browser-tested result

got_base=$(md5sum dash/index.html | cut -d' ' -f1)
if [ "$got_base" != "$EXPECT_BASE" ]; then
  echo "dash/index.html has changed since this was built ($got_base, expected $EXPECT_BASE)."
  echo "The splice anchors may have moved. Re-derive the build rather than forcing it."
  exit 1
fi

TMP=$(mktemp -d)
cat > "$TMP/section.html" <<'FRAG_SECTION'

  <!-- ========== LOT (PPI / impounds) ========== -->
  <section id="vLot" style="display:none">
    <div class="search">
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4">
        <circle cx="11" cy="11" r="7"></circle><path d="M21 21l-4.3-4.3"></path>
      </svg>
      <input id="lSearch" type="text" inputmode="search" placeholder="Plate, VIN, call #, address, make"
             oninput="renderLot()" autocomplete="off">
    </div>
    <div class="chips wrap" id="lChips"></div>
    <div id="lList"><div class="empty">Loading&hellip;</div></div>
  </section>
FRAG_SECTION
cat > "$TMP/sheet.html" <<'FRAG_SHEET'

<!-- impound detail: the TOP form itself -->
<div class="sheet" id="shImp">
  <button class="close" onclick="closeSheets()">&times;</button>
  <h3 id="impName"></h3>
  <div class="shsub" id="impSub"></div>
  <div id="impBody"></div>
</div>

<!-- status change -->
<div class="sheet" id="shImpStatus">
  <button class="close" onclick="closeSheets()">&times;</button>
  <h3 id="impStTitle">Change status</h3>
  <div class="shsub" id="impStSub"></div>
  <div id="impStList"></div>
  <label>Note (optional)</label>
  <input id="impStNote" type="text" placeholder="never towed -- lot was empty">
  <button class="btn" onclick="saveImpStatus()">Save status</button>
</div>
FRAG_SHEET
cat > "$TMP/lot.js" <<'FRAG_LOT'

/* ==========================================================
   LOT -- PPI / impounds

   The unit of work on this tab is the TOP form, not the list.
   Fino's ask: "i need to be able to edit the top form info
   before i generate it." So the detail view IS the form --
   every field that prints on the notification is an input,
   and Generate saves first, then renders from the saved row.
   The PDF and the record can therefore never disagree.
   ========================================================== */
var LOT=null, LOTDET=null, lotFilter='work', lotStTarget=null;

var LOT_FILTERS=[
  ['work','Being worked'],
  ['vin','No VIN'],
  ['pretow','No call-in'],
  ['top','No TOP'],
  ['walk','Lot walk'],
  ['all','All']
];

function loadLot(quiet){
  api('dashImpounds',[KEYV()],function(d){ LOT=d; renderLotChips(); renderLot() }, quiet, 'Loading lot');
}
function lotSetFilter(f){ lotFilter=f; renderLotChips(); renderLot() }

function renderLotChips(){
  if(!LOT) return;
  var c=LOT.counts, n={work:c.custody-c.lotWalk, vin:c.noVin, pretow:c.noPretow, top:c.noTop, walk:c.lotWalk, all:c.total};
  $('lChips').innerHTML=LOT_FILTERS.map(function(f){
    return '<button class="chip'+(lotFilter===f[0]?' on':'')+'" onclick="lotSetFilter(\''+f[0]+'\')">'+
           f[1]+' '+(n[f[0]]||0)+'</button>';
  }).join('');
}

function lotMatch(r){
  if(lotFilter==='all')    return true;
  if(lotFilter==='work')   return r.working;
  if(lotFilter==='vin')    return r.f_vin;
  if(lotFilter==='pretow') return r.f_pretow;
  if(lotFilter==='top')    return r.f_top;
  if(lotFilter==='walk')   return r.status==='UNKNOWN_DISPOSITION';
  return true;
}

function renderLot(){
  if(!LOT) return;
  var q=($('lSearch').value||'').trim().toLowerCase();
  var rows=LOT.rows.filter(function(r){
    if(!lotMatch(r)) return false;
    if(!q) return true;
    return (r.plate+' '+r.vin+' '+r.call+' '+r.from+' '+r.vehicle+' '+r.juris+' '+r.id)
             .toLowerCase().indexOf(q)>=0;
  });
  var v=$('lList');
  if(!rows.length){ v.innerHTML='<div class="empty">Nothing here.<br>Try another filter.</div>'; return }
  var cap=rows.length>150?150:rows.length;
  var h='';
  for(var i=0;i<cap;i++) h+=lotCard(rows[i]);
  if(rows.length>cap) h+='<div class="empty">'+(rows.length-cap)+' more — search to narrow it down.</div>';
  v.innerHTML=h;
}

function lotStatusPill(r){
  var lab=(LOT&&LOT.labels&&LOT.labels[r.status])||r.status||'—';
  var cls='dim';
  if(r.status==='INTAKE') cls='info';
  else if(r.status==='GOA') cls='purple';
  else if(r.status==='RELEASED'||r.status==='TRANSFERRED') cls='';
  else if(r.status==='UNKNOWN_DISPOSITION') cls='dim';
  else if(r.custody) cls='ok';
  return '<span class="pill '+cls+'">'+esc(lab)+'</span>';
}

function lotCard(r){
  var title=r.vehicle||'Unknown vehicle';
  var idline=[];
  if(r.plate) idline.push(r.plate);
  if(r.vin) idline.push(r.vin.length===17?r.vin:(r.vin+' (partial)'));
  if(!idline.length) idline.push('no plate, no VIN');
  var flags='';
  if(r.f_vin)    flags+='<span class="pill bad">No VIN</span> ';
  if(r.f_pretow) flags+='<span class="pill warn">No call-in</span> ';
  if(r.f_top)    flags+='<span class="pill warn">No TOP</span> ';
  var age=(r.days===''||r.days==null)?'':(r.days+'d');
  return '<div class="card" onclick="openImp(\''+esc(r.id)+'\')">'+
    '<div class="row"><div class="nm">'+esc(title)+'</div>'+lotStatusPill(r)+'</div>'+
    '<div class="sub mono">'+esc(idline.join(' · '))+'</div>'+
    '<div class="sub2">'+esc(r.juris||'no department set')+
      (r.from?' · '+esc(r.from):'')+'</div>'+
    '<div class="sub2">call '+esc(r.call)+(r.tow_date?' · '+esc(r.tow_date):'')+
      (r.tow_time?' '+esc(r.tow_time):'')+(age?' · '+age+' ago':'')+'</div>'+
    (flags?'<div class="docs" style="flex-wrap:wrap;gap:4px">'+flags+'</div>':'')+
  '</div>';
}

/* ---------- detail = the TOP form ---------- */
function openImp(id){
  api('dashImpound',[id,KEYV()],function(d){
    LOTDET=d;
    $('impName').textContent=[d.fields.Year,d.fields.Make,d.fields.Model].filter(Boolean).join(' ')||'Unknown vehicle';
    $('impSub').textContent='Call '+d.call+' · '+d.id+' · '+(d.status_label||d.status);
    $('impBody').innerHTML=impBody(d);
    openSheet('shImp');
  }, false, 'Loading');
}

function fld(id,label,val,ph,type){
  return '<label for="'+id+'">'+label+'</label>'+
    '<input id="'+id+'" type="'+(type||'text')+'" value="'+esc(val||'')+'"'+
    (ph?' placeholder="'+esc(ph)+'"':'')+' autocomplete="off">';
}

function impBody(d){
  var f=d.fields||{}, j=d.juris;
  var h='';

  /* --- status + what this vehicle is --- */
  h+='<div class="block"><span class="lbl">Status</span>';
  h+='<div class="row" style="margin-bottom:8px"><div class="nm">'+esc(d.status_label||d.status)+'</div>'+
     (d.custody?'<span class="pill ok">In custody</span>':'<span class="pill dim">Not in custody</span>')+'</div>';
  h+='<button class="btn sec sm" onclick="openImpStatus()">Change status</button>';
  if(d.status!=='GOA'){
    h+='<button class="btn sec sm" onclick="quickGoa()">Mark GOA — never towed</button>';
  }
  h+='</div>';

  /* --- the department, because it decides everything else --- */
  h+='<div class="block"><span class="lbl">Department</span>';
  h+='<select id="f_Jurisdiction" onchange="impJurisChanged()">';
  h+='<option value="">— pick a department —</option>';
  (LOT&&LOT.jurisdictions||[]).forEach(function(x){
    h+='<option value="'+esc(x.name)+'"'+(x.name===f.Jurisdiction?' selected':'')+'>'+esc(x.name)+'</option>';
  });
  h+='</select>';
  h+='<div id="impJurisNote">'+impJurisNote(j)+'</div>';
  h+='</div>';

  /* --- pre-tow check: the compliance gate, before the paperwork --- */
  h+='<div class="block"><span class="lbl">Pre-tow check</span>';
  h+='<div class="sub2" style="margin-bottom:6px">'+esc(j?j.pretow_how:'Pick a department to see how they want the VIN run.')+'</div>';
  h+='<label for="f_Police_Notified_At">Ran at</label>'+
     '<div class="krow"><input id="f_Police_Notified_At" type="text" value="'+esc(f.Police_Notified_At||'')+
     '" placeholder="2026-09-06 11:02" autocomplete="off">'+
     '<button class="kbtn" onclick="impNow()">Now</button></div>';
  h+=fld('f_Complaint_No','Complaint / ref #',f.Complaint_No,'FT-26-8890');
  if(d.has_officer_col && (!j || j.pretow!=='phone')){
    h+=fld('f_Pretow_Officer','Officer on scene (name / badge)',f.Pretow_Officer,'Ofc. Ramirez #412');
  }
  h+='</div>';

  /* --- vehicle --- */
  h+='<div class="block"><span class="lbl">Vehicle</span>';
  h+='<div class="two"><div>'+fld('f_Year','Year',f.Year,'2005')+'</div>'+
     '<div>'+fld('f_Make','Make',f.Make,'Chrysler')+'</div></div>';
  h+=fld('f_Model','Model',f.Model,'Pacifica');
  h+=fld('f_VIN','VIN',f.VIN,'17 characters, no I/O/Q');
  h+='<div class="two"><div>'+fld('f_Plate','Plate',f.Plate,'33ACZ7')+'</div>'+
     '<div>'+fld('f_Plate_State','State',f.Plate_State,'MI')+'</div></div>';
  h+='</div>';

  /* --- the tow --- */
  h+='<div class="block"><span class="lbl">The tow</span>';
  h+='<div class="two"><div>'+fld('f_Tow_Date','Date',f.Tow_Date,'2026-09-06')+'</div>'+
     '<div>'+fld('f_Tow_Time','Time',f.Tow_Time,'11:18')+'</div></div>';
  h+=fld('f_Tow_From','Towed from',f.Tow_From,'2324 Austins Pkwy');
  h+='<div class="two"><div>'+fld('f_Tow_From_City','City',f.Tow_From_City,'Flint')+'</div>'+
     '<div>'+fld('f_Tow_From_Zip','Zip',f.Tow_From_Zip,'48507')+'</div></div>';
  h+=fld('f_Requestor','Requested by',f.Requestor,'PROPERTY OWNER');
  h+=fld('f_Lot','Stored at',f.Lot,'iTow Dolan Drive');
  h+='</div>';

  // Every dash write goes out as a GET query string (file 20: POST belongs to
  // the SMS webhook and is never touched), so a pasted wall of text would blow
  // the URL and fail in a way that reads as "did it save?". Cap it here.
  h+='<div class="block"><span class="lbl">Notes</span>'+
     '<textarea id="f_Notes" maxlength="500" placeholder="Anything the next person needs to know">'+esc(f.Notes||'')+'</textarea></div>';

  h+='<button class="btn" onclick="genTop()">Save &amp; generate TOP</button>';
  h+='<button class="btn sec" onclick="saveImp()">Save only</button>';

  /* --- what has already gone out --- */
  if(d.docs&&d.docs.length){
    h+='<div class="block" style="margin-top:14px"><span class="lbl">Forms on file</span>';
    d.docs.forEach(function(x){
      h+='<div class="kv"><span class="k">'+esc(x.type)+'</span><span class="v">'+
         '<a href="'+esc(x.url)+'" target="_blank" rel="noopener" style="border-bottom:1px solid var(--line2)">'+
         esc(x.at||'open')+'</a></span></div>';
    });
    h+='</div>';
  }

  /* --- the clocks, read-only: they are computed, not typed --- */
  var c=d.clocks||{};
  if(c.lein||c.sos||c.redemption||c.sale){
    h+='<div class="block"><span class="lbl">Legal clock</span>';
    h+=kv('LEIN',esc(c.lein||'—')+(c.lein_est==='estimated'?' <span class="pill dim">est</span>':''));
    h+=kv('SOS notice',esc(c.sos||'—')+(c.sos_est==='estimated'?' <span class="pill dim">est</span>':''));
    h+=kv('Redemption',esc(c.redemption||'—'));
    h+=kv('Sale eligible',esc(c.sale||'—'));
    h+='</div>';
  }

  if(d.events&&d.events.length){
    h+='<div class="block"><span class="lbl">History</span>';
    d.events.slice(0,8).forEach(function(e){
      h+='<div class="note"><div class="meta">'+esc(e.at)+' · '+esc(e.actor)+' · '+esc(e.type)+'</div>'+
         '<div class="txt">'+esc(e.details)+'</div></div>';
    });
    h+='</div>';
  }
  return h;
}

function impJurisNote(j){
  if(!j) return '<div class="warnbox" style="margin-top:9px">No department set. The TOP cannot be generated until one is picked — it decides the fax number, the contact and the wording.</div>';
  var bits=[];
  // notify_how already names the contact ("text TOP to Todd Johnson ..."),
  // so repeating it underneath just reads as a stutter on a phone screen.
  var how=String(j.notify_how||'');
  if(j.contact && how.indexOf(j.contact)<0) bits.push(j.contact);
  if(j.fax)   bits.push('fax '+j.fax);
  if(j.phone) bits.push(j.phone);
  if(j.email) bits.push(j.email);
  var note='<div class="sub2" style="margin-top:8px">'+esc(j.notify_how||'')+'</div>';
  if(bits.length) note+='<div class="sub2">'+esc(bits.join(' · '))+'</div>';
  if(j.paperwork==='none'){
    note+='<div class="warnbox" style="margin-top:9px">Call-in only — no TOP form. Record the complaint number above and mark it notified.</div>';
  }
  if(j.quirks) note+='<div class="sub2" style="margin-top:6px;color:var(--ink3)">'+esc(j.quirks)+'</div>';
  return note;
}

function impJurisChanged(){
  var name=$('f_Jurisdiction').value;
  var j=(LOT&&LOT.jurisdictions||[]).filter(function(x){ return x.name===name })[0];
  $('impJurisNote').innerHTML=impJurisNote(j?{
    name:j.name, pretow:j.pretow, paperwork:j.paperwork, contact:j.contact,
    fax:j.fax, phone:j.phone, email:j.email,
    notify_how:'', quirks:''
  }:null);
}

function impNow(){
  var d=new Date(), p=function(n){ return (n<10?'0':'')+n };
  $('f_Police_Notified_At').value=d.getFullYear()+'-'+p(d.getMonth()+1)+'-'+p(d.getDate())+' '+p(d.getHours())+':'+p(d.getMinutes());
}

var IMP_FIELDS=['Jurisdiction','Police_Notified_At','Complaint_No','Pretow_Officer','Year','Make','Model',
                'VIN','Plate','Plate_State','Tow_Date','Tow_Time','Tow_From','Tow_From_City','Tow_From_Zip',
                'Requestor','Lot','Notes'];

function impCollect(){
  var o={};
  IMP_FIELDS.forEach(function(f){ var el=$('f_'+f); if(el) o[f]=el.value });
  return o;
}

function saveImp(){
  if(!LOTDET) return;
  api('dashSaveImpound',[LOTDET.id,impCollect(),KEYV()],function(r){
    toast(r.note||'Saved.');
    loadLot(true);
    openImp(LOTDET.id);
  }, false, 'Saving');
}

function genTop(){
  if(!LOTDET) return;
  api('dashImpoundTop',[LOTDET.id,impCollect(),KEYV()],function(r){
    loadLot(true);
    var msg='TOP ready';
    if(r.warnings&&r.warnings.length) msg+=' — '+r.warnings.join('; ');
    toast(msg);
    window.open(r.url,'_blank');
    openImp(LOTDET.id);
  }, false, 'Generating TOP');
}

/* ---------- status ---------- */
function openImpStatus(){
  if(!LOTDET) return;
  lotStTarget=LOTDET.id;
  $('impStSub').textContent=(LOTDET.fields.Make||'')+' '+(LOTDET.fields.Model||'')+' · call '+LOTDET.call;
  $('impStNote').value='';
  $('impStList').innerHTML=(LOTDET.statuses||[]).map(function(s){
    var lab=(LOTDET.labels&&LOTDET.labels[s])||s;
    return '<button class="btn sec sm" onclick="pickImpStatus(this,\''+s+'\')" data-s="'+s+'">'+esc(lab)+'</button>';
  }).join('');
  impStPick=LOTDET.status;
  openSheet('shImpStatus');
}
var impStPick=null;
function pickImpStatus(btn,s){
  impStPick=s;
  var all=$('impStList').querySelectorAll('.btn');
  for(var i=0;i<all.length;i++) all[i].className='btn sec sm';
  btn.className='btn sm';
}
function saveImpStatus(){
  if(!lotStTarget||!impStPick) { toast('Pick a status first.',true); return }
  api('dashImpoundStatus',[lotStTarget,impStPick,$('impStNote').value,KEYV()],function(r){
    toast(r.note||'Saved.');
    closeSheets(); loadLot(true);
  }, false, 'Saving');
}
function quickGoa(){
  if(!LOTDET) return;
  api('dashImpoundStatus',[LOTDET.id,'GOA','',KEYV()],function(r){
    toast(r.note||'Marked GOA.');
    closeSheets(); loadLot(true);
  }, false, 'Saving');
}
FRAG_LOT

mkdir -p dash-next
python3 - "$TMP" <<'PYEOF'
import sys, pathlib
t = pathlib.Path(sys.argv[1])
src = pathlib.Path('dash/index.html').read_text()
sec = (t/'section.html').read_text()
sh  = (t/'sheet.html').read_text()
js  = (t/'lot.js').read_text()

old = """    <div class="tab"    id="tabPeople" onclick="showTab('people')">People<span class="dot" id="applDot" style="display:none">0</span></div>"""
assert src.count(old) == 1, 'tab anchor'
src = src.replace(old, """    <div class="tab"    id="tabLot"    onclick="showTab('lot')">Lot<span class="dot" id="lotDot" style="display:none">0</span></div>\n""" + old)
src = src.replace("""  <!-- ========== SCHEDULE ========== -->""", sec.rstrip('\n') + "\n\n  <!-- ========== SCHEDULE ========== -->")
src = src.replace("""<!-- applicant note -->""", sh.strip() + "\n\n<!-- applicant note -->")
src = src.replace("""                 dashShifts:1, dashConfigList:1, dashDiag:1 };""", """                 dashShifts:1, dashConfigList:1, dashDiag:1,
                 dashImpounds:1, dashImpound:1 };""")
src = src.replace("""  var map={today:'tabToday',people:'tabPeople'""", """  var map={today:'tabToday',lot:'tabLot',people:'tabPeople'""")
src = src.replace("""  $('vToday').style.display    = t==='today'?'':'none';""", """  $('vToday').style.display    = t==='today'?'':'none';\n  $('vLot').style.display      = t==='lot'?'':'none';""")
src = src.replace("""  if(t==='shifts'   && !SH)  loadShifts();""", """  if(t==='lot'      && !LOT) loadLot(false);\n  if(t==='shifts'   && !SH)  loadShifts();""")
i = src.rfind('</script>')
src = src[:i] + js.rstrip('\n') + "\n\n" + src[i:]
pathlib.Path('dash-next/index.html').write_text(src)
print('built dash-next/index.html', len(src), 'chars')
PYEOF

got_out=$(md5sum dash-next/index.html | cut -d' ' -f1)
if [ "$got_out" != "$EXPECT_OUT" ]; then
  echo "REFUSING TO PUSH: rebuilt file is $got_out, expected $EXPECT_OUT."
  exit 1
fi
echo "md5 matches the browser-tested build: $got_out"
rm -rf "$TMP"

git add dash-next/index.html
git commit -q -m "Add the Lot tab: PPI / impound vehicles on the dashboard

The detail view IS the TOP form: every field that prints on the
notification is an input, and Generate saves to the row first then
renders the PDF from the row, so paperwork and record cannot drift.
Filters show what is actually wrong (No VIN / No call-in / No TOP) and
deliberately skip the pre-lot-walk seed rows. Server side is
25_dash_impounds.gs, registered in 20_dash_server.gs v3.13.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push origin main
echo "pushed. Cloudflare publishes /dash-next/ in about a minute."
