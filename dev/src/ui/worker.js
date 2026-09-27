// SPDX-License-Identifier: GPL-3.0-or-later
/* THE CORE'S OWN THREAD. The page has one thread for the screen, the clicks
   and everything else; while the core computed on it, the window stood still.
   So the core lives here, apart, and the page only sends it jobs and draws
   what comes back. This text runs after the pipeline (src/ui/pipeline.js),
   which the page puts in front of it.

   Jobs go one after another, in the order sent. A long one runs in parts of
   about a frame: between them it hands out what can be shown already and
   hears whether the page has dropped it. A picture to show goes out only when
   the page has drawn the previous one — a slow phone gets fewer pictures, not
   a queue of them.

   The image lies at the bottom of the core's memory for as long as the work is
   open; every job gives back everything above it before it starts. */
let E=null, img=0, imgW=0, imgH=0, imageTop=0, rowsDone=0;
const waiting=[], dropped=new Set();
let now=null, drawn=true, busy=false;
const PART_MS=14;
const LINKS_PER_CALL=16384;   // stage 2: links resolved per call
const CLUSTERS_PER_CALL=256;  // stage 3: a cluster is weighed against every paint so far
onmessage=e=>{
  const m=e.data;
  if(m.boot){
    WebAssembly.instantiate(m.boot,{env:{rowDone:j=>{ rowsDone=j+1; }}})
      .then(r=>{ E=r.instance.exports; postMessage({ready:true}); next(); })
      .catch(err=>postMessage({failed:String(err)}));
    return;
  }
  if(m.drop){
    for(const id of m.drop) dropped.add(id);
    if(now && dropped.has(now.id)) now.dropped=true;
    return;
  }
  // The page drew a picture of the job running now: the next may go. An ack
  // for a job already dropped says nothing about this one.
  if(m.drawn){ if(now && m.drawn===now.id) drawn=true; return; }
  waiting.push(m); next();
};
async function next(){
  if(busy||!E) return;
  busy=true;
  while(waiting.length){
    const job=waiting.shift();
    if(dropped.delete(job.id)){ postMessage({id:job.id, dropped:true}); continue; }
    now={id:job.id, dropped:false}; drawn=true;
    let answer;
    try{ answer=await JOBS[job.kind](job.data, now); }
    catch(err){ answer={value:null, error:String(err && err.stack || err)}; }
    dropped.delete(job.id);
    if(now.dropped) postMessage({id:job.id, dropped:true});
    else postMessage({id:job.id, value:answer.value, error:answer.error}, answer.give||[]);
    now=null;
  }
  busy=false;
}
// A turn for the messages from the page. Not setTimeout: after a few in a
// row a browser stretches it to 4 ms.
const turn=()=>new Promise(r=>{ const ch=new MessageChannel(); ch.port1.onmessage=()=>r(); ch.port2.postMessage(0); });
/* Runs step() until it stops returning 1, in parts of about a frame. Returns
   the last code (-1 — the page dropped the job) and the time spent computing. */
async function inParts(job, step, show){
  let code=1, spent=0;
  for(;;){
    const t=performance.now();
    do code=step(); while(code===1 && performance.now()-t<PART_MS);
    spent+=performance.now()-t;
    if(code!==1) return {code, spent};
    if(show && drawn){ drawn=false; show(); }
    await turn();
    if(job.dropped) return {code:-1, spent};
  }
}
const fresh=()=>E.freeMemoryTo(imageTop);
const JOBS={
  // A new image: the page's decoded picture, read out here and kept as RGB.
  // Reading a big picture's pixels takes a while — not on the page's thread.
  image(d){
    let s;
    try{
      const c=new OffscreenCanvas(d.w,d.h), x=c.getContext('2d');
      x.drawImage(d.bitmap,0,0);
      s=x.getImageData(0,0,d.w,d.h).data;
    } finally { d.bitmap.close(); }
    // Room is asked for first, above what is kept: refused, the image open
    // before stays whole.
    if(!(E.allocMemory(d.w*d.h*3)>>>0)){ fresh(); return {value:false}; }
    E.resetMemory();
    img=E.allocMemory(d.w*d.h*3)>>>0; imgW=d.w; imgH=d.h;
    const mm=new Uint8Array(E.memory.buffer);
    for(let i=0,j=img;i<s.length;i+=4,j+=3){ mm[j]=s[i]; mm[j+1]=s[i+1]; mm[j+2]=s[i+2]; }
    imageTop=E.memoryTop();
    return {value:true};
  },
  grid(){ fresh(); return {value:{found:searchGrid(E,img,imgW,imgH)}}; },
  advice(d){ fresh(); return {value:advice(E,d.step,d.meas)}; },
  // Stage 1: the rows done so far go out as RGBA strips.
  async pass1(d, job){
    fresh(); rowsDone=0;
    const pass=beginPass1(E,img,imgW,imgH,d.gx,d.gy,d.k,d.share), nw=pass.nx;
    if(pass.code!==1) return {value:{code:pass.code}};
    let sent=0;
    const show=()=>{
      const from=sent, to=rowsDone;
      if(to<=from){ drawn=true; return; }
      sent=to;
      const src=new Uint8Array(E.memory.buffer,pass.out+from*nw*3,(to-from)*nw*3);
      const rgba=new Uint8ClampedArray((to-from)*nw*4);
      for(let i=0,k=0;i<src.length;i+=3,k+=4){ rgba[k]=src[i]; rgba[k+1]=src[i+1]; rgba[k+2]=src[i+2]; rgba[k+3]=255; }
      postMessage({id:job.id, rows:{from,to,rgba}}, [rgba.buffer]);
    };
    const {code,spent}=await inParts(job,()=>pass.rows(1),show);
    if(code!==3) return {value:{code}};
    const t=performance.now();
    const meas=pass.end();
    const art=new Uint8Array(E.memory.buffer,pass.out,pass.nx*pass.ny*3).slice();
    return {value:{code:1, meas, art, msec:spent+performance.now()-t}, give:[art.buffer]};
  },
  // Stage 2: with `shown`, the groups as they stand go out over it.
  async pass2(d, job){
    fresh();
    const pass=beginPass2(E,d.art,d.nw,d.nh,d.k,d.joints,d.shown);
    if(pass.code!==1) return {value:null};          // nothing to count
    const show=d.shown ? ()=>{ const px=pass.preview(); postMessage({id:job.id, preview:px}, [px.buffer]); } : null;
    let spent=0;
    if(pass.code===1){
      const r=await inParts(job,()=>pass.links(LINKS_PER_CALL),show);
      if(r.code<0) return {value:null};
      spent=r.spent;
    }
    const t=performance.now();
    const r=pass.end(); r.msec=spent+performance.now()-t;
    return {value:r, give:[r.art.buffer, r.label.buffer]};
  },
  // Stage 3: with `shown`, the paints laid so far go out over it.
  async pass3(d, job){
    fresh();
    const pass=beginPass3(E,d.label,d.nw,d.nh,d.cc,d.k,d.spread,d.shown);
    if(pass.code!==1) return {value:null};          // nothing to lay, or no room
    const show=d.shown ? ()=>{ const px=pass.preview(); postMessage({id:job.id, preview:px}, [px.buffer]); } : null;
    let spent=0;
    if(pass.code===1){
      const r=await inParts(job,()=>pass.clusters(CLUSTERS_PER_CALL),show);
      if(r.code<0) return {value:null};
      spent=r.spent;
    }
    const t=performance.now();
    const r=pass.end(); r.msec=spent+performance.now()-t;
    return {value:r, give:[r.art.buffer, r.where.buffer, r.palette.buffer]};
  },
};
