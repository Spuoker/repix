// SPDX-License-Identifier: GPL-3.0-or-later
/* THE PIPELINE — how the page drives the core, as pure functions: no page,
   no knobs, no drawing. Everything a stage computes goes through here: the
   grid search, the cell borders, the automatic settings, the three passes.

   The build puts this file into repix.html as it is, at the start of the
   page's script; the page calls these functions with its knob values. The
   test bench imports the very same file, so the tests run exactly what the
   program runs, and there is no second copy to drift apart.

   E is the core's exports. Memory is the core's: a function allocates what it
   needs after what is already there, and reads its answers out before the
   next call. */

/* The grid search looks for a step in this range; the step knob has the same
   range, so a step the knob allows is one the search can find. */
export const GRID_STEP={min:1, max:40};

/* WHERE THE KNOBS START — the values a pass gets before anything is measured
   or set by hand. The page's knobs start here, and so do the tests. The
   agreement share is the core's word; until the first advice it is this. */
export const KNOB_START={
  jitter:0, colorTolerance:2, noiseMultiple:2, cap:0, overlap:1.5,
  placeWidth:0.12, surroundWeight:1, agreement:2,
  neighbourStrictness:0.5, maxDrift:0, maxPaints:0};
export const AGREEMENT_SHARE_START=0.4;

/* A cut-off cell at the edge is kept if at least this share of it remains.
   Measured on 27 pairs: 0.50 gives one extra cell at worst and no lost ones,
   0.60 the opposite. An extra cell is cropped in two seconds, a lost row
   comes back from nowhere — so 0.50. */
export const CROP_SHARE=0.5;

// Helpers of this file only; the page shares its scope, so their names are
// kept apart from the page's own.
const f64=(E,addr,n)=>new Float64Array(E.memory.buffer,addr,n);
// A refused room (0) is an error: writing through it would overwrite the
// core's own memory from its first byte.
const alloc=(E,n)=>{ const p=E.allocMemory(n)>>>0; if(!p) throw new Error('out of memory'); return p; };
function copyIn(E,bytes){ const p=alloc(E,bytes.length); new Uint8Array(E.memory.buffer,p,bytes.length).set(bytes); return p; }

/** The grid of an image already in the core's memory at img (RGB). */
export function searchGrid(E,img,w,h){
  const addr=alloc(E,8*8);
  if(!E.findGrid(img,w,h,GRID_STEP.min,GRID_STEP.max,addr)) return null;
  const g=f64(E,addr,8);
  return {step:g[0], ox:g[1], oy:g[2], coherence:g[7]};
}

/* CELL BORDERS along one axis: the even grid from step and origin, each line
   moved by shift(k) (a line fixed by hand), plus the cut-offs at the edges —
   pieces of real art pixels cut by cropping. Their mean color is the same
   color, just from fewer samples, so they are kept when they hold at least
   CROP_SHARE of a cell and two samples. A cut-off is not checked against the
   detected art frame: the frame detector does not count white fields around
   a work as art, and the work would lose its edge row. */
export function borders(limit,step,origin,shift=()=>0){
  const k0=Math.ceil(-origin/step), k1=Math.floor((limit-origin)/step);
  const gg=[];
  for(let k=k0;k<=k1;k++) gg.push(origin+k*step+shift(k));
  if(gg.length<2) return gg;
  const few=Math.max(2, step*CROP_SHARE);
  if(gg[0]>=few) gg.unshift(0);
  if(limit-gg[gg.length-1]>=few) gg.push(limit);
  return gg;
}

/* STAGE 1 KNOBS, as the pass takes them:
     {jitter, colorTolerance, noiseMultiple, cap, overlap, agreement,
      placeWidth, surroundWeight}
   THE EFFECTIVE TOLERANCE is the larger of a floor in color units and a
   multiple of the noise, but never above the cap, if one is set: no wider
   than where two different paints meet. AGREEMENT is a share of the
   tolerance (the share comes from the core with the advice), the agreement
   knob being its floor. */
export function tolerance(k){
  let dd=Math.max(k.colorTolerance, k.noiseMultiple*k.jitter);
  if(k.cap>0 && dd>k.cap) dd=k.cap;
  return dd;
}
export function agreement(k,share){
  return Math.max(k.agreement, share*tolerance(k));
}

/** Pass 1 IN PARTS, so a page can show the art growing: a browser paints only
    between calls, and one call over the whole picture would show it only when
    done. beginPass1 lays the pass out and returns it:
      code   — 1: begun; 0: too few borders;
      out    — where the art lies in memory (nx*ny RGB cells);
      rows(n) — runs n more rows: 1 — rows are left, 3 — all done,
               2 — a cell window does not fit;
      end()  — the measurements of the picture (see the end of pass1.zig).
    The work of each row is the same as in one whole pass, and so is the result. */
export function beginPass1(E,img,w,h,gx,gy,k,share){
  const nx=gx.length-1, ny=gy.length-1;
  const pgx=alloc(E,gx.length*8), pgy=alloc(E,gy.length*8);
  f64(E,pgx,gx.length).set(gx);
  f64(E,pgy,gy.length).set(gy);
  const out=alloc(E,nx*ny*3), broken=alloc(E,nx*ny), meas=alloc(E,8*16);
  E.setSurroundWeight(k.surroundWeight);
  E.setPlaceWidth(k.placeWidth);
  const code=E.pass1Begin(img,w,h,pgx,nx,pgy,ny,k.overlap,tolerance(k),agreement(k,share),out,broken,meas);
  return {code, nx, ny, out,
          rows:n=>E.pass1Rows(n),
          // The core writes twelve measurements (meas[0..11]).
          end:()=>{ E.pass1End(); return Array.from(f64(E,meas,12)); }};
}
/** Pass 1 whole: the same parts, run at once. Returns the core's code
    (1 — done, 0 — too few borders, 2 — a cell window does not fit), where the
    art lies in memory and the measurements. */
export function pass1(E,img,w,h,gx,gy,k,share){
  const pp=beginPass1(E,img,w,h,gx,gy,k,share);
  if(pp.code!==1) return {code:pp.code, nx:pp.nx, ny:pp.ny, out:pp.out, meas:[]};
  const done=pp.rows(pp.ny);
  if(done===2) return {code:2, nx:pp.nx, ny:pp.ny, out:pp.out, meas:[]};
  return {code:1, nx:pp.nx, ny:pp.ny, out:pp.out, meas:pp.end()};
}

/** THE CORE'S ADVICE for stage 1, from the grid step and the measurements
    of pass 1 — as knob values. The jitter is the measured one, if measured. */
export function advice(E,step,meas){
  const am=alloc(E,8*16);
  f64(E,am,meas.length).set(meas);
  const addr=alloc(E,8*8);
  E.autoParams(step,am,addr);
  const [multiple,overlap,share,half,ceiling]=f64(E,addr,5);
  return {jitter: meas[4]>0 ? +meas[9].toFixed(1) : null,
          colorTolerance:half, noiseMultiple:multiple, cap:+ceiling.toFixed(1),
          overlap, agreement:half, agreementShare:share, ceiling};
}

/* JOINTS. For every pair of neighbouring cells that differ, the difference in
   lightness and in tone is taken separately and both rows are sorted. They
   give the picture's own units of difference. An AXIS's unit is counted over
   joints where that axis takes part at all: on an almost grey work the tone
   row would fill with zeros from pure lightness steps, and the whole tone
   axis would die. */
function splitDiff(dr,dg,db){
  const along=(dr+dg+db)/1.7320508075688772;
  let across=dr*dr+dg*dg+db*db-along*along; if(across<0) across=0;
  return [Math.abs(along), Math.sqrt(across)];
}
export function jointsOf(art,nw,nh){
  const S=[], T=[];
  const pair=(i,j)=>{
    const dr=art[i]-art[j], dg=art[i+1]-art[j+1], db=art[i+2]-art[j+2];
    if(!dr&&!dg&&!db) return;
    const [ds,dt]=splitDiff(dr,dg,db);
    if(ds>0) S.push(ds);
    if(dt>0) T.push(dt);
  };
  for(let y=0;y<nh;y++) for(let x=0;x<nw;x++){
    const i=(y*nw+x)*3;
    if(x+1<nw) pair(i,i+3);
    if(y+1<nh) pair(i,i+nw*3);
  }
  S.sort((a,b)=>a-b); T.sort((a,b)=>a-b);
  return {S,T};
}
/** A share (0..100) of a sorted row, as a threshold in color units. */
export function fromShare(row,p){
  if(!row||!row.length||p<=0) return 0;
  return row[Math.min(row.length-1,Math.floor(row.length*p/100))]+1e-6;
}

/* OUR OWN CELL NOISE. Jitter is the spread inside a cell measured by stage 1;
   a cell averages "pixels per cell" samples, so its own noise is about
   jitter / sqrt(pixels). Anything finer is our dirt, not the author's intent. */
export function cellNoise(meas,jitter){
  if(!meas||meas[4]<=0) return 1;
  return Math.max(0.2, jitter/Math.sqrt(Math.max(1,meas[3])));
}
/* STAGE 2 AUTOMATIC SETTINGS. The smallest paint is a share of all cells —
   one sixtieth: 273 cells on a 128x128 icon, 640 on a 160x240 work; the gauge
   is the median joint in lightness; cell noise as above. */
export function groupAdvice(nw,nh,joints,meas,jitter){
  return {minPaint:Math.max(4,Math.round(nw*nh/60)),
          gauge:+fromShare(joints.S,50).toFixed(1),
          cellNoise:+cellNoise(meas,jitter).toFixed(2)};
}
/** Pass 2 IN PARTS, like pass 1: beginPass2 measures and sorts the links and
    returns the pass:
      code     — 1: begun; 0: nothing to do;
      links(n) — resolves n more links: 1 — links are left, 3 — all done;
      preview() — the groups as they stand, for the eye only, drawn over
                  `shown` (the picture on screen, nx*ny RGBA, or nothing):
                  a cell that has joined a group gets the group's mean color,
                  one still on its own keeps what was there;
      end()    — {groups, art, label, mS, mT}: the clusters and their colors.
    k = {cellNoise, minPaint, gauge}; the gauge is in lightness, the tone gauge
    keeps the work's own proportion of the median joints in tone and in
    lightness. The result is that of one whole call. */
export function beginPass2(E,art,nw,nh,k,joints,shown){
  const mS0=fromShare(joints.S,50), mT0=fromShare(joints.T,50);
  const mS=k.gauge, mT=mS0>0 ? mS*mT0/mS0 : mS;
  const p=copyIn(E,art), out=alloc(E,art.length), lab=alloc(E,nw*nh*4);
  E.setCellNoise(k.cellNoise); E.setMinGroup(k.minPaint); E.setGauge(mS,mT);
  const over=alloc(E,nw*nh*4);
  const view=()=>new Uint8ClampedArray(E.memory.buffer,over,nw*nh*4);
  if(shown) view().set(shown); else view().fill(0);
  const code=E.pass2Begin(p,nw,nh,out,lab);
  return {code,
    links:n=>E.pass2Links(n),
    preview:()=>{ E.pass2Preview(over); return view().slice(); },
    end:()=>{ const groups=E.pass2End();
      return {groups, mS, mT,
              art:new Uint8Array(E.memory.buffer,out,art.length).slice(),
              label:new Int32Array(E.memory.buffer,lab,nw*nh).slice()}; }};
}
/** Pass 2 whole: the same parts, run at once. */
export function pass2(E,art,nw,nh,k,joints){
  const pp=beginPass2(E,art,nw,nh,k,joints);
  if(pp.code===1) while(pp.links(1<<30)===1);
  return pp.end();
}

/* STAGE 3 — MERGING. Each cluster's color comes from its first cell met (a
   cluster has one color); the order clusters are first met in is kept, it is
   the order the spread probes them in. */
export function clusterColors(art,label){
  let mx=0; for(let i=0;i<label.length;i++) if(label[i]>mx) mx=label[i];
  const colors=new Uint8Array((mx+1)*3), seen=new Uint8Array(mx+1), order=[];
  for(let i=0;i<label.length;i++){
    const g=label[i]; if(g<0||seen[g]) continue;
    colors.set(art.subarray(i*3,i*3+3), g*3); seen[g]=1; order.push(g);
  }
  return {colors, count:mx+1, order};
}
/* THE SPREAD: thresholds of stage 3 are shares of the differences BETWEEN
   CLUSTER COLORS, not between neighbouring cells — another unit than on
   stage 2. The scale is built from the distance to the NEAREST cluster, not
   over all pairs: random pairs lie far apart, and the nearest neighbour is
   exactly the distance merging eats. At most about 600 clusters are probed. */
export function spreadOf(cc){
  const N=cc.order.length, STEP=Math.max(1,Math.floor(N/600)), probe=[];
  for(let i=0;i<N;i+=STEP){ const g=cc.order[i]; probe.push([cc.colors[g*3],cc.colors[g*3+1],cc.colors[g*3+2]]); }
  const S=[], T=[];
  for(let a=0;a<probe.length;a++){
    let best=Infinity, bs=0, bt=0;
    for(let b=0;b<probe.length;b++){
      if(a===b) continue;
      const dr=probe[a][0]-probe[b][0], dg=probe[a][1]-probe[b][1], db=probe[a][2]-probe[b][2];
      if(!dr&&!dg&&!db) continue;
      const d=dr*dr+dg*dg+db*db;
      if(d<best){ best=d; [bs,bt]=splitDiff(dr,dg,db); }
    }
    if(best<Infinity){ S.push(bs); T.push(bt); }
  }
  S.sort((a,b)=>a-b); T.sort((a,b)=>a-b);
  return {S,T};
}
/* STAGE 3 AUTOMATIC SETTINGS: the smallest paint total is a sixteenth of all
   cells, the merge gauge the median distance to the nearest cluster. */
export function mergeAdvice(nw,nh,spread){
  return {minPaintTotal:Math.max(8,Math.round(nw*nh/16)),
          mergeGauge:+Math.max(0.3,fromShare(spread.S,50)).toFixed(1)};
}
/** Pass 3 IN PARTS, like passes 1 and 2: beginPass3 weighs and orders the
    clusters and returns the pass:
      code        — 1: begun; 0: nothing to do;
      clusters(n) — lays n more clusters into paints, largest first:
                    1 — clusters are left, 3 — all done;
      preview()   — the paints as they stand, for the eye only, drawn over
                    `shown` (nx*ny RGBA, or nothing);
      end()       — {paints, mS, mT, art, where, palette}.
    k = {mergeGauge, neighbourStrictness, maxDrift, minPaintTotal, maxPaints}.
    The result is that of one whole call: the art, which paint each cluster
    went to, and the palette — color and cells of each paint. */
export function beginPass3(E,label,nw,nh,cc,k,spread,shown){
  const total=nw*nh;
  const mS0=Math.max(0.3,fromShare(spread.S,50)), mT0=Math.max(0.3,fromShare(spread.T,50));
  const mS=Math.max(0.01,k.mergeGauge), mT=mS0>0 ? mS*mT0/mS0 : mS;
  const pl=alloc(E,total*4);
  new Int32Array(E.memory.buffer,pl,total).set(label);
  const pc=copyIn(E,cc.colors), out=alloc(E,total*3), target=alloc(E,cc.count*4);
  const over=alloc(E,total*4);
  const view=()=>new Uint8ClampedArray(E.memory.buffer,over,total*4);
  if(shown) view().set(shown); else view().fill(0);
  E.setNeighbourStrictness(k.neighbourStrictness);
  E.setMaxDrift(k.maxDrift);
  const code=E.pass3Begin(pl,total,nw,nh,cc.count,pc,mS,mT,k.minPaintTotal,k.maxPaints,out,target);
  return {code,
    clusters:n=>E.pass3Clusters(n),
    preview:()=>{ E.pass3Preview(over); return view().slice(); },
    end:()=>{
      const paints=E.pass3End();
      const art=new Uint8Array(E.memory.buffer,out,total*3).slice();
      const where=new Uint32Array(E.memory.buffer,target,cc.count).slice();
      // Read as many paints as the core actually put out: its palette space is
      // limited, and with zero thresholds there are far more paints than fit.
      const n=E.gatherPalette(pl,total,target,cc.count,pc);
      const palette=f64(E,E.paletteAddress()>>>0,n*4).slice();
      return {paints, mS, mT, art, where, palette}; }};
}
/** Pass 3 whole: the same parts, run at once. */
export function pass3(E,label,nw,nh,cc,k,spread){
  const pp=beginPass3(E,label,nw,nh,cc,k,spread);
  if(pp.code===1) while(pp.clusters(1<<30)===1);
  return pp.end();
}
