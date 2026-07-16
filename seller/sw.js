// PhoneHub Pro — Seller service worker
// Handles incoming Web Push events so alerts show up (with sound + vibration)
// even when the app isn't open, and routes taps back into the app.

self.addEventListener('install', function(event){
  self.skipWaiting();
});

self.addEventListener('activate', function(event){
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', function(event){
  var data = {};
  try{ data = event.data ? event.data.json() : {}; }
  catch(e){ data = { title: 'PhoneHub Pro', body: event.data ? event.data.text() : '' }; }

  var title = data.title || 'PhoneHub Pro';
  var options = {
    body: data.body || '',
    icon: './icon-192.png',
    badge: './icon-192.png',
    // Default device notification sound plays automatically unless silent:true —
    // the Web Notification API doesn't support a custom .mp3, but vibration +
    // the OS's own alert tone is what gets a dealer's attention even screen-off.
    silent: false,
    vibrate: [250, 100, 250, 100, 250],
    tag: data.tag || ('phonehub-' + (data.type || 'alert')),
    renotify: true,
    requireInteraction: data.type === 'request' || data.type === 'broadcast',
    data: { url: data.url || './', type: data.type || 'alert' }
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', function(event){
  event.notification.close();
  var targetPath = (event.notification.data && event.notification.data.url) || './';
  var notifType = (event.notification.data && event.notification.data.type) || 'alert';

  if (targetPath === './' || targetPath === '.' || targetPath === ''){
    var typeToPath = {
      request: './#tab=requests',
      broadcast: './#tab=network',
      warranty: './#tab=sales',
      stock: './#tab=inventory',
      response: './#tab=network'
    };
    targetPath = typeToPath[notifType] || './';
  }

  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function(clientList){
      for (var i = 0; i < clientList.length; i++){
        var client = clientList[i];
        if ('focus' in client){
          client.focus();
          if ('navigate' in client) { try { client.navigate(targetPath); } catch(e){} }
          return;
        }
      }
      if (self.clients.openWindow) return self.clients.openWindow(targetPath);
    })
  );
});