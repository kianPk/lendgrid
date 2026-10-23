
const $ = id => document.getElementById(id);
const S = { coll:0, debt:0, eth:3000, ltv:0.75, thr:0.80, bonus:0.05 };
function usdColl(){ return S.coll * S.eth; }
function hf(){ if(!S.debt) return Infinity; return (usdColl()*S.thr)/S.debt; }
function log(m){ const el=$('log'); const t=new Date().toLocaleTimeString(); el.textContent=`[${t}] ${m}\n`+el.textContent.slice(0,2000); }
function render(){
  const h=hf();
  $('kpis').innerHTML=[
    ['Collateral USD', Math.round(usdColl()).toLocaleString()],
    ['Debt USD', Math.round(S.debt).toLocaleString()],
    ['Health factor', h===Infinity?'∞':h.toFixed(3)],
    ['ETH price', '$'+S.eth],
  ].map(([l,v])=>`<div class="kpi"><div class="l">${l}</div><div class="v" style="${l==='Health factor'&&h<1?'color:var(--bad)':''}">${v}</div></div>`).join('');
}
$('actions').innerHTML=`
<button class="btn primary" id="dep">Deposit</button>
<button class="btn ghost" id="borrow">Borrow</button>
<button class="btn ghost" id="crash">Crash ETH -30%</button>
<button class="btn ghost" id="liq">Liquidate $1k</button>`;
$('dep').onclick=()=>{ S.coll=+($('coll').value||0); S.eth=+($('px').value||3000); log(`deposit ${S.coll} WETH @ $${S.eth}`); render(); };
$('borrow').onclick=()=>{ const want=+($('bor').value||0); const max=usdColl()*S.ltv; if(S.debt+want>max){ log(`revert InsufficientCollateral (max $${max.toFixed(0)})`); return;} S.debt+=want; log(`borrow $${want}`); render(); };
$('crash').onclick=()=>{ S.eth=Math.round(S.eth*0.7); $('px').value=S.eth; log(`oracle update ETH → $${S.eth}`); render(); };
$('liq').onclick=()=>{ if(hf()>=1){ log('revert HealthyPosition'); return;} const repay=1000; const seizeUsd=repay*(1+S.bonus); const seize=seizeUsd/S.eth; S.debt=Math.max(0,S.debt-repay); S.coll=Math.max(0,S.coll-seize); log(`liquidate repay=$1000 seize=${seize.toFixed(4)} WETH (+5% bonus)`); render(); };
render(); log('LendGrid demo ready — LTV 75% · liq threshold 80% · bonus 5%');
