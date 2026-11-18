/* Service worker: la card si apre anche con connessione debole o assente. */
var V='tessera-v7';
var CORE=['./','index.html','privacy.html','termini.html','manifest.webmanifest','icon-192.png','icon-512.png','apple-touch-icon.png'];
self.addEventListener('install',function(e){
  e.waitUntil(caches.open(V).then(function(c){return c.addAll(CORE);}).then(function(){return self.skipWaiting();}));
});
self.addEventListener('activate',function(e){
  e.waitUntil(caches.keys().then(function(ks){return Promise.all(ks.filter(function(k){return k!==V;}).map(function(k){return caches.delete(k);}));}).then(function(){return self.clients.claim();}));
});
self.addEventListener('fetch',function(e){
  var r=e.request; if(r.method!=='GET') return;
  var url=new URL(r.url); if(url.protocol!=='http:'&&url.protocol!=='https:') return;
  /* prima la rete (così gli aggiornamenti arrivano subito), se manca si usa la copia salvata */
  e.respondWith(fetch(r).then(function(res){
    if(res&&(res.status===200||res.type==='opaque')){var cp=res.clone(); caches.open(V).then(function(c){c.put(r,cp);});}
    return res;
  }).catch(function(){
    return caches.match(r,{ignoreSearch:true}).then(function(m){return m||(r.mode==='navigate'?caches.match('index.html'):Response.error());});
  }));
});
