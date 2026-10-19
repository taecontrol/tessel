import Compression
import Foundation

private enum CaptureRenderingError: Error { case compression }

/// Replay only measured frames. Keep the evidence portable: no external assets,
/// screen images, native titles, or synthetic spring/interpolated geometry.
func carouselCaptureHTML(_ data: Data) throws -> String {
    var bytes = [UInt8](repeating: 0, count: data.count + 1024)
    let count = data.withUnsafeBytes { source in
        compression_encode_buffer(&bytes, bytes.count, source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
    }
    guard count > 0 else { throw CaptureRenderingError.compression }
    // Apple's ZLIB codec emits raw DEFLATE. Native browser decompression keeps
    // every measured sample in a portable page small enough for inline review.
    let payload = Data(bytes.prefix(count)).base64EncodedString()
    return #"""
    <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Carousel · measured fixture motion</title><style>
    :root{color-scheme:light dark}*{box-sizing:border-box}body{margin:0;color:var(--foreground,CanvasText);font:14px -apple-system,system-ui,sans-serif}main{max-width:1120px;margin:auto;padding:4px 0 20px}h1{font-size:20px;margin:12px 0}p{line-height:1.5;margin:8px 0;color:var(--muted-foreground,GrayText)}label{font-size:12px;display:grid;gap:5px}select,button{font:inherit;background:var(--card,Canvas);color:inherit;border:1px solid var(--border,#555);border-radius:6px;padding:7px;min-width:0}button{cursor:pointer}button:focus-visible,select:focus-visible,input:focus-visible{outline:2px solid #7aa2ff}.controls{display:grid;grid-template-columns:1fr 2fr;gap:12px;margin:16px 0}.transport{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:10px 0}.transport input{flex:1;min-width:120px}output{font:12px ui-monospace,monospace}svg{width:100%;display:block}.screen{background:radial-gradient(at 15% 10%,#3b4d6b,#151c2b);border-radius:10px}.stats{font:12px ui-monospace,monospace;line-height:1.8;margin:12px 0}.film{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px}.film button{padding:0;border:2px solid transparent;background:transparent;text-align:left}.film button.selected{border-color:#7aa2ff}.film span{display:block;font:11px ui-monospace,monospace;padding:5px}.plot{height:160px;background:var(--card,Canvas);border-radius:8px;margin:8px 0}table{width:100%;border-collapse:collapse;font:12px ui-monospace,monospace;margin:12px 0}td,th{text-align:left;padding:6px;border-bottom:1px solid var(--border,#444)}.legend{display:flex;flex-wrap:wrap;gap:12px;font-size:12px}.pending{color:#d9a54a}details{margin:12px 0}summary{cursor:pointer}a{color:#7aa2ff}@media(max-width:550px){.controls{grid-template-columns:1fr}.film{grid-template-columns:repeat(2,minmax(0,1fr))}table{font-size:10px}td,th{padding:5px 2px}}
    </style><main>
    <h1>Carousel · measured fixture motion</h1>
    <p class="pending">E21 · Pending owner review · 80 ms and 400 ms</p>
    <p>Independent AX/CG observations of the signed app, sampled on delivered display callbacks. WindowServer rectangles and answered AX focus are measured; titles and numbered contents are invented. No Screen Recording or desktop screenshots. Compare these journeys with the accepted navigation prototype.</p>
    <div class="controls"><label>Journey and configured duration<select id="journey"></select></label><label>Command<select id="step"></select></label></div>
    <div class="transport"><button id="play">Play</button><button id="previous" aria-label="Previous sample">←</button><button id="next" aria-label="Next sample">→</button><label>Replay speed<select id="speed"><option value="1">1×</option><option value="0.25">¼×</option></select></label><input id="scrub" aria-label="Observed frame" type="range" min="0" value="0"><output id="time"></output></div>
    <svg id="screen" class="screen" role="img" aria-label="Measured fixture rectangles"></svg>
    <div id="stats" class="stats"></div><div id="legend" class="legend"></div>
    <div class="transport"><label>Geometry timeline<select id="property"><option value="0">X position</option><option value="1">Y position</option><option value="2">Width</option></select></label><span>Click the timeline to inspect a sample.</span></div>
    <svg id="plot" class="plot" viewBox="0 0 720 160" preserveAspectRatio="none" role="img" aria-label="Per-window geometry timeline"></svg>
    <div id="film" class="film"></div>
    <table><thead><tr><th>Window</th><th>X</th><th>Y</th><th>W</th><th>H</th><th>CG / focus</th><th>Bounds</th></tr></thead><tbody id="frames"></tbody></table>
    <details><summary>How to read this capture</summary><p>Playback holds each actual sample until the next one; no frames are interpolated. The filmstrip selects observed samples, including the baseline and settled tail. The timeline includes measured geometry even while a window is hidden; only CG-visible rectangles are drawn in the screen. The highest rectangle in CG order is drawn last. A blue outline marks the answered AX focus.</p><p>WindowServer supplies window bounds without waiting for the app. Missing descriptions fall back to short AX reads; the table identifies the source. Each sample has a raw-clock start and end; CG order is read after geometry. Display callback intervals and read spans are reported below, exposing skipped callbacks and slow reads. An unanswered AX read is shown as unavailable, never inferred to be hidden. The open command starts at the request timestamp; key commands start at the fixture's real key post.</p><p>The signed observer validates fixture identities, never queries titles, and discovers the newly opened fixture through fixture-owned CG window IDs. All data are embedded in this file. The capture is visual evidence for the owner, not a latency gate. Timing percentiles belong to the separate native latency suite.</p></details>
    <p id="provenance"></p><button id="download">Download observations JSON</button>
    </main><script type="module">
    const packed=Uint8Array.from(atob('__CAPTURE_DATA__'),c=>c.charCodeAt(0));
    const data=JSON.parse(await new Response(new Blob([packed]).stream().pipeThrough(new DecompressionStream('deflate-raw'))).text());
    const $=id=>document.getElementById(id),ns='http://www.w3.org/2000/svg';
    const colors=['#8ab4f8','#99cf9c','#cba6f7','#f3bc79','#f08c99'],titles=['Editor','Terminal','Browser','Notes','Mail'];
    let ji=0,si=0,fi=0,playing=false,epoch=0,first=0,raf=0;
    const journey=()=>data.journeys[ji],step=()=>journey().steps[si],sample=()=>step().samples[fi];
    const ms=s=>(s.startedAt-step().postedAt)*1000;
    const rounded=x=>Number(x).toFixed(1);
    function el(tag,attrs={},text=''){const n=document.createElementNS(ns,tag);for(const[k,v]of Object.entries(attrs))n.setAttribute(k,v);n.textContent=text;return n}
    function option(select,text,value){const o=document.createElement('option');o.textContent=text;o.value=value;select.append(o)}
    data.journeys.forEach((j,i)=>option($('journey'),`${j.example} · ${j.duration} ms`,i));
    function drawScreen(svg,s){const j=journey(),[sx,sy,sw,sh]=j.screen;svg.replaceChildren();svg.setAttribute('viewBox',`0 0 ${sw} ${sh}`);
      svg.append(el('rect',{x:0,y:0,width:sw,height:j.area[1]-10,fill:'#151820'}));svg.append(el('text',{x:20,y:Math.max(20,j.area[1]-22),fill:'#ddd','font-size':20},'Fixture desktop · invented contents'));
      svg.append(el('rect',{x:j.area[0]-sx,y:j.area[1]-sy,width:j.area[2],height:j.area[3],fill:'none',stroke:'#b8c9e0','stroke-dasharray':'5 5',opacity:.3}));
      for(const id of [...s.order].reverse()){const w=s.windows.find(w=>w.id===id);if(!w||!w.valid||!w.visible)continue;const n=j.windows.indexOf(id);if(n<0)continue;const[x,y,width,height]=w.frame,g=el('g'),c=colors[n%5];
        g.append(el('rect',{x:x-sx,y:y-sy,width,height,rx:8,fill:n%2?'#1e1f24':'#fbfbfd',stroke:s.focused===id?'#73a6ff':'#111','stroke-width':s.focused===id?5:1}));
        g.append(el('rect',{x:x-sx+1,y:y-sy+1,width:Math.max(0,width-2),height:30,rx:7,fill:s.focused===id?c:'#c7c9cf'}));
        g.append(el('text',{x:x-sx+width/2,y:y-sy+22,'text-anchor':'middle',fill:'#24272c','font-size':17},`${n+1} · ${titles[n%5]}`));
        for(let line=0;line<7;line++)g.append(el('rect',{x:x-sx+24,y:y-sy+62+line*27,width:Math.max(0,Math.min(width-48,(width-48)*(.5+.4*((line%3)/2)))),height:8,rx:4,fill:n%2?'#424756':'#dfe2e8'}));
        g.append(el('text',{x:x-sx+width-25,y:y-sy+Math.min(height-25,220),'text-anchor':'end',fill:c,'font-size':95,'font-weight':700},n+1));svg.append(g);
      }
    }
    function drawPlot(){const p=$('plot'),j=journey(),st=step(),prop=+$('property').value;p.replaceChildren();const valid=st.samples.flatMap(s=>s.windows.filter(w=>w.valid).map(w=>w.frame[prop])),lo=Math.min(0,...valid),hi=Math.max(j.screen[prop===1?3:2],...valid),a=ms(st.samples[0]),b=ms(st.samples.at(-1)),X=t=>40+(t-a)/(b-a||1)*665,Y=v=>132-(v-lo)/(hi-lo||1)*112;
      for(let k=0;k<3;k++){const v=lo+(hi-lo)*k/2,y=Y(v);p.append(el('line',{x1:40,x2:705,y1:y,y2:y,stroke:'#687080',opacity:.3}));p.append(el('text',{x:3,y:y+4,fill:'#999','font-size':9},Math.round(v)))}
      j.windows.forEach((id,i)=>{let path='',pen=false;for(const s of st.samples){const w=s.windows.find(w=>w.id===id);if(!w?.valid){pen=false;continue}path+=`${pen?'L':'M'}${X(ms(s))},${Y(w.frame[prop])} `;pen=true}p.append(el('path',{d:path,fill:'none',stroke:colors[i%5],'stroke-width':2}))});
      p.append(el('line',{x1:X(0),x2:X(0),y1:10,y2:140,stroke:'#d9a54a','stroke-dasharray':'3 3'}));p.append(el('line',{x1:X(ms(sample())),x2:X(ms(sample())),y1:10,y2:140,stroke:'#ddd'}));p.append(el('text',{x:40,y:154,fill:'#999','font-size':10},`${rounded(a)} ms`));p.append(el('text',{x:705,y:154,fill:'#999','font-size':10,'text-anchor':'end'},`${rounded(b)} ms`));
    }
    function frame(index){fi=Math.max(0,Math.min(step().samples.length-1,index));$('scrub').value=fi;const s=sample(),j=journey();drawScreen($('screen'),s);$('time').textContent=`${rounded(ms(s))} ms · sample ${fi+1}/${step().samples.length}`;$('frames').replaceChildren();
      j.windows.forEach((id,i)=>{const w=s.windows.find(w=>w.id===id),row=document.createElement('tr'),values=[`${i+1} · ${titles[i%5]}`,...(w?.valid?w.frame.map(rounded):['—','—','—','—']),w?.valid?`${w.visible?'shown':'hidden'}${s.focused===id?' · focused':''}`:'unavailable',w?.source||'—'];values.forEach(v=>{const td=document.createElement('td');td.textContent=v;row.append(td)});$('frames').append(row)});
      document.querySelectorAll('.film button').forEach(b=>b.classList.toggle('selected',+b.dataset.index===fi));drawPlot();
    }
    function stop(){playing=false;cancelAnimationFrame(raf);$('play').textContent='Play'}
    function selectStep(){stop();fi=0;const st=step(),j=journey();$('scrub').max=st.samples.length-1;$('film').replaceChildren();const end=Math.max(j.duration,140)+50;
      const indices=[0,...Array.from({length:6},(_,i)=>st.samples.reduce((best,s,k)=>Math.abs(ms(s)-i*end/5)<Math.abs(ms(st.samples[best])-i*end/5)?k:best,0)),st.samples.length-1];
      [...new Set(indices)].sort((a,b)=>a-b).forEach(i=>{const button=document.createElement('button'),svg=el('svg',{class:'screen'}),caption=document.createElement('span');button.dataset.index=i;drawScreen(svg,st.samples[i]);caption.textContent=`${rounded(ms(st.samples[i]))} ms · #${i+1}`;button.append(svg,caption);button.onclick=()=>{stop();frame(i)};$('film').append(button)});
      const gaps=st.samples.slice(1).map((s,i)=>(s.at-st.samples[i].at)*1000).sort((a,b)=>a-b),spans=st.samples.map(s=>(s.sampledAt-s.startedAt)*1000),bad=st.samples.filter(s=>s.windows.some(w=>!w.valid)).length,unknownFocus=st.samples.filter(s=>!s.focused).length;
      $('stats').textContent=`${st.samples.length} delivered callbacks · median interval ${rounded(gaps[Math.floor(gaps.length/2)]||0)} ms · maximum interval ${rounded(Math.max(0,...gaps))} ms · max AX/CG read span ${rounded(Math.max(...spans))} ms · ${bad} samples with unavailable bounds · ${unknownFocus} unanswered focus samples. ${st.eventClock}.`;
      $('legend').replaceChildren();j.windows.forEach((id,i)=>{const s=document.createElement('span');s.textContent=`● ${i+1} · ${titles[i%5]}`;s.style.color=colors[i%5];$('legend').append(s)});frame(0);
    }
    function selectJourney(){ji=+$('journey').value;si=0;$('step').replaceChildren();journey().steps.forEach((s,i)=>option($('step'),s.command,i));selectStep()}
    $('journey').onchange=selectJourney;$('step').onchange=()=>{si=+$('step').value;selectStep()};$('scrub').oninput=()=>{stop();frame(+$('scrub').value)};$('previous').onclick=()=>{stop();frame(fi-1)};$('next').onclick=()=>{stop();frame(fi+1)};$('property').onchange=drawPlot;
    $('play').onclick=()=>{if(playing){stop();return}if(fi===step().samples.length-1)frame(0);playing=true;epoch=performance.now();first=ms(sample());$('play').textContent='Pause';const tick=now=>{if(!playing)return;const t=first+(now-epoch)*+$('speed').value;let i=fi;while(i+1<step().samples.length&&ms(step().samples[i+1])<=t)i++;if(i!==fi)frame(i);if(fi===step().samples.length-1){stop();return}raf=requestAnimationFrame(tick)};raf=requestAnimationFrame(tick)};
    $('plot').onclick=e=>{const r=$('plot').getBoundingClientRect(),f=Math.max(0,Math.min(1,((e.clientX-r.left)/r.width*720-40)/665)),ss=step().samples,t=ms(ss[0])+f*(ms(ss.at(-1))-ms(ss[0]));stop();frame(ss.reduce((best,s,i)=>Math.abs(ms(s)-t)<Math.abs(ms(ss[best])-t)?i:best,0))};
    $('download').onclick=()=>{const a=document.createElement('a'),url=URL.createObjectURL(new Blob([JSON.stringify(data)],{type:'application/json'}));a.href=url;a.download='carousel-motion.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000)};
    $('provenance').textContent=`Captured ${data.measuredAt}. Commit ${data.commit.slice(0,12)}${data.workingTreeDirty?' + working changes':''}; app ${data.appVersion}. ${data.source}. Review remains pending.`;
    if(data.journeys.length)selectJourney();console.log(JSON.stringify({journeys:data.journeys.length,steps:data.journeys.reduce((n,j)=>n+j.steps.length,0),review:data.reviewStatus}));document.dispatchEvent(new Event("capture-ready"));
    </script></html>
    """#.replacingOccurrences(of: "__CAPTURE_DATA__", with: payload)
}
