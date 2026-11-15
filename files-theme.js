(() => {
  'use strict';
  const pre = document.querySelector('body > pre');
  if (!pre) return;
  const path = decodeURIComponent(location.pathname.replace(/^\/files\/?/, '')).split('/').filter(Boolean);
  const icon = (href, name) => {
    if (href.endsWith('/')) return '📁';
    const ext = (name.split('.').pop() || '').toLowerCase();
    if (['mp4', 'mkv', 'avi', 'mov', 'webm', 'm4v'].includes(ext)) return '▶';
    if (['srt', 'vtt', 'ass'].includes(ext)) return 'CC';
    if (['torrent'].includes(ext)) return '🧲';
    if (['jpg', 'jpeg', 'png', 'webp', 'gif'].includes(ext)) return '◈';
    return '↓';
  };
  const type = (href, name) => {
    if (href.endsWith('/')) return 'folder';
    const ext = (name.split('.').pop() || '').toLowerCase();
    return ['mp4', 'mkv', 'avi', 'mov', 'webm', 'm4v'].includes(ext) ? 'video' : 'file';
  };
  const top = document.createElement('div');
  top.className = 'ds-topbar';
  top.innerHTML = '<div class="ds-topbar-inner"><div class="ds-brand"><span class="ds-logo">↓</span><span>Download Vault</span></div><a class="ds-panel-btn" href="/"><span>Back to AriaNg</span><b>↗</b></a></div>';
  const shell = document.createElement('main');
  shell.className = 'ds-shell';
  const hero = document.createElement('section');
  hero.className = 'ds-hero';
  hero.innerHTML = '<div class="ds-kicker">Secure VPS storage</div><h2>Your files, <span class="ds-gradient">ready to download.</span></h2><p class="ds-subtitle">Open a folder or click any file to stream and download it directly from your server.</p>';
  const crumbs = document.createElement('nav');
  crumbs.className = 'ds-path';
  let cumulative = '/files/';
  crumbs.innerHTML = '<a class="ds-crumb" href="/files/">Downloads</a>';
  path.forEach(part => {
    cumulative += encodeURIComponent(part) + '/';
    crumbs.insertAdjacentHTML('beforeend', '<span class="ds-sep">/</span><a class="ds-crumb" href="' + cumulative + '">' + part.replace(/[<>&"]/g, c => ({ '<': '<', '>': '>', '&': '&', '"': '"' }[c])) + '</a>');
  });
  hero.appendChild(crumbs);
  const grid = document.createElement('section');
  grid.className = 'ds-grid';
  const links = [...pre.querySelectorAll('a')].filter(a => a.getAttribute('href') !== '../');
  for (const a of links) {
    const href = a.getAttribute('href');
    const name = a.textContent.replace(/\.\.>$/, '…').trim();
    let meta = '';
    let n = a.nextSibling;
    if (n && n.nodeType === 3) meta = n.textContent.trim();
    const card = document.createElement('article');
    card.className = 'ds-card ' + type(href, name);
    card.dataset.href = href;
    card.dataset.name = name;
    const link = document.createElement('a');
    link.className = 'ds-card-link';
    link.href = href;
    link.innerHTML = '<span class="ds-icon">' + icon(href, name) + '</span><span class="ds-name"></span><span class="ds-meta"></span>';
    link.querySelector('.ds-name').textContent = name;
    link.querySelector('.ds-meta').textContent = href.endsWith('/') ? 'Folder' : (meta || 'File');
    const delBtn = document.createElement('button');
    delBtn.className = 'ds-del-btn';
    delBtn.setAttribute('aria-label', 'Delete ' + name);
    delBtn.innerHTML = '🗑';
    delBtn.addEventListener('click', async (e) => {
      e.preventDefault();
      e.stopPropagation();
      if (!confirm('Delete "' + name + '"?')) return;
      delBtn.disabled = true;
      delBtn.textContent = '…';
      try {
        const relPath = path.concat([name]).map(encodeURIComponent).join('/');
        const resp = await fetch('/api/delete/' + relPath, {
          method: 'DELETE',
          credentials: 'include'
        });
        const data = await resp.json();
        if (resp.ok) {
          card.style.animation = 'ds-fade-out 0.3s ease forwards';
          setTimeout(() => card.remove(), 300);
        } else {
          alert('Failed: ' + (data.error || resp.status));
          delBtn.disabled = false;
          delBtn.textContent = '🗑';
        }
      } catch (err) {
        alert('Error: ' + err.message);
        delBtn.disabled = false;
        delBtn.textContent = '🗑';
      }
    });
    card.appendChild(link);
    card.appendChild(delBtn);
    grid.appendChild(card);
  }
  if (!links.length) grid.innerHTML = '<div class="ds-empty">This folder is empty.</div>';
  shell.append(hero, grid);
  const foot = document.createElement('footer');
  foot.className = 'ds-footer';
  foot.textContent = 'aria2 Download Server • Private file access';
  document.body.prepend(top);
  document.body.append(shell, foot);
  const style = document.createElement('style');
  style.textContent = '.ds-del-btn{position:absolute;top:10px;right:10px;width:34px;height:34px;border-radius:10px;border:1px solid rgba(239,68,68,.3);background:rgba(239,68,68,.1);color:#ef4444;font-size:14px;cursor:pointer;opacity:0;transition:opacity .15s ease,transform .15s ease,background .15s ease;display:grid;place-items:center}.ds-card:hover .ds-del-btn{opacity:1}.ds-del-btn:hover{background:rgba(239,68,68,.25);border-color:rgba(239,68,68,.6);transform:scale(1.08)}.ds-del-btn:disabled{opacity:.6;cursor:not-allowed}@keyframes ds-fade-out{to{opacity:0;transform:translateY(-8px);height:0;margin:0;padding:0;overflow:hidden}}@media(max-width:600px){.ds-del-btn{opacity:1}}';
  document.head.appendChild(style);
})();