export function connectFolder(api, server) {
  const folder = document.querySelector('#download-folder');
  const show = document.querySelector('#show-downloads');
  const refresh = document.querySelector('#refresh-downloads');
  const toggleTrash = document.querySelector('#toggle-trash');
  const emptyTrash = document.querySelector('#empty-trash');
  const title = document.querySelector('#download-folder-title');
  const breadcrumbs = document.querySelector('#download-path');
  const items = document.querySelector('#download-items');
  const message = document.querySelector('#download-folder-status');
  const search = document.querySelector('#file-search');
  const searchLabel = folder.querySelector('label[for="file-search"]');
  const kind = document.querySelector('#file-kind');
  const kindControl = document.querySelector('#file-kind-control');
  const sort = document.querySelector('#file-sort');
  const count = document.querySelector('#file-count');
  const storage = document.querySelector('#vps-storage');
  const meter = document.querySelector('#storage-meter');
  const percentage = document.querySelector('#storage-percent');
  const capacity = document.querySelector('#storage-capacity');
  const collator = new Intl.Collator(undefined, {numeric: true, sensitivity: 'base'});
  const sizes = new Intl.NumberFormat(undefined, {maximumFractionDigits: 1});
  const dates = new Intl.DateTimeFormat(undefined, {dateStyle: 'medium'});
  const numbers = new Intl.NumberFormat();
  const plural = new Intl.PluralRules();
  let currentPath = '';
  let inTrash = false;
  let trashRevision;
  let request;
  let writing = false;
  let entries;
  let filesSort = sort.value;
  let trashSort = 'newest';

  function formatSize(bytes) {
    const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
    let unit = 0;
    while (bytes >= 1024 && unit < units.length - 1) {
      bytes /= 1024;
      unit++;
    }
    return sizes.format(bytes) + ' ' + units[unit];
  }

  function button(label, action) {
    const control = document.createElement('button');
    control.type = 'button';
    control.textContent = label;
    control.addEventListener('click', action);
    return control;
  }

  function openPath(path) {
    if (path !== currentPath) {
      search.value = '';
      kind.value = 'all';
    }
    currentPath = path;
    load();
  }

  function renderPath() {
    breadcrumbs.replaceChildren();
    if (inTrash) return;

    breadcrumbs.append(button('Downloads', () => openPath('')));
    const parts = currentPath.split('/').filter(Boolean);
    for (const [index, name] of parts.entries()) {
      const separator = document.createElement('span');
      separator.setAttribute('aria-hidden', 'true');
      separator.textContent = '/';
      if (index === parts.length - 1) {
        const current = document.createElement('span');
        current.setAttribute('aria-current', 'page');
        current.textContent = name;
        breadcrumbs.append(separator, current);
      } else {
        breadcrumbs.append(separator, button(name, () => openPath(parts.slice(0, index + 1).join('/'))));
      }
    }
  }

  function renderStorage(disk) {
    if (!disk || !Number.isFinite(disk.total) || disk.total <= 0 || !Number.isFinite(disk.free)) {
      storage.hidden = true;
      return;
    }
    const free = Math.min(disk.total, Math.max(0, disk.free));
    const used = Math.round(100 * (disk.total - free) / disk.total);
    meter.value = used;
    meter.classList.toggle('is-low', used >= 90);
    percentage.textContent = used + '% used';
    capacity.textContent = formatSize(free) + ' available of ' + formatSize(disk.total);
    storage.hidden = false;
  }

  function entryLabel(total) {
    return numbers.format(total) + (plural.select(total) === 'one' ? ' item' : ' items');
  }

  function updateItems() {
    if (!entries) return;
    const query = search.value.trim().toLocaleLowerCase();
    const filter = inTrash ? 'all' : kind.value;
    const matches = {
      all: () => true,
      files: file => !file.folder,
      folders: file => file.folder,
      videos: file => file.kind === 'video',
      active: file => file.active
    };
    const files = entries.filter(file =>
      matches[filter](file) && (!query || [file.name, file.title].some(text => text?.toLocaleLowerCase().includes(query)))
    );
    const nameOrder = (first, second) => collator.compare(first.name, second.name);
    const compare = {
      name: (first, second) => inTrash ? 0 : Number(second.folder) - Number(first.folder),
      newest: (first, second) => (second.modified ?? second.deleted ?? 0) - (first.modified ?? first.deleted ?? 0),
      largest: (first, second) => second.size - first.size,
      smallest: (first, second) => first.size - second.size
    };
    files.sort((first, second) => compare[sort.value](first, second) || nameOrder(first, second));
    renderItems(files);

    count.textContent = files.length === entries.length
      ? entryLabel(entries.length)
      : numbers.format(files.length) + ' of ' + entryLabel(entries.length);
    if (!entries.length) message.textContent = inTrash ? 'Trash is empty.' : 'This folder is empty.';
    else message.textContent = files.length ? '' : 'No matching items.';
  }

  function renderItems(files) {
    const rows = document.createDocumentFragment();
    for (const file of files) {
      const item = document.createElement('li');
      const name = !inTrash && file.folder ? button(file.name, () => openPath(file.path)) : document.createElement('span');
      const icon = document.createElement('i');
      icon.className = file.folder ? 'fa fa-folder' : file.kind === 'video' ? 'fa fa-film' : 'fa fa-file-o';
      icon.setAttribute('aria-hidden', 'true');
      name.className = 'file-name';
      name.replaceChildren(icon, document.createTextNode(file.name));

      const controls = document.createElement('div');
      controls.className = 'file-actions';
      const size = document.createElement('span');
      size.className = 'file-size';
      size.textContent = file.active ? 'In use · ' + formatSize(file.size) : formatSize(file.size);
      controls.append(size);

      if (inTrash) {
        controls.append(button('Restore', () => mutate('library/restore', 'POST', {id: file.id})));
      } else {
        if (!file.folder) controls.append(button('Download', event => download(file, event.currentTarget)));
        const remove = button('Delete', () => mutate('library/item', 'DELETE', {path: file.path}));
        remove.className = 'file-delete';
        remove.disabled = file.active === true;
        controls.append(remove);
      }
      const details = document.createElement('div');
      details.className = 'file-details';
      details.append(name);
      const timestamp = file.modified ?? file.deleted;
      if (timestamp) {
        const metadata = document.createElement('small');
        metadata.className = 'file-date';
        metadata.textContent = (inTrash ? 'Deleted ' : '') + dates.format(timestamp * 1000);
        details.append(metadata);
      }
      item.append(details, controls);
      rows.append(item);
    }
    items.replaceChildren(rows);
  }

  async function load() {
    if (request) request.abort();
    const controller = new AbortController();
    request = controller;
    title.textContent = inTrash ? 'Trash' : 'Download folder';
    toggleTrash.textContent = inTrash ? 'Back to Files' : 'Trash';
    trashRevision = undefined;
    emptyTrash.hidden = true;
    entries = undefined;
    count.textContent = '';
    kindControl.hidden = inTrash;
    searchLabel.textContent = inTrash ? 'Search Trash' : 'Search this folder';
    renderPath();
    items.replaceChildren();
    message.textContent = inTrash ? 'Loading Trash…' : 'Loading files…';
    refresh.disabled = true;

    try {
      const url = new URL(inTrash ? 'library/trash' : 'library', server);
      if (!inTrash && currentPath) url.searchParams.set('path', currentPath);
      const result = await api(url, {
        signal: AbortSignal.any([controller.signal, AbortSignal.timeout(15000)])
      });
      if (controller.signal.aborted) return;
      entries = result.items;
      renderStorage(result.disk);
      updateItems();
      if (inTrash && result.items.length) {
        trashRevision = result.revision;
        emptyTrash.hidden = false;
      }
    } catch (error) {
      if (!controller.signal.aborted) message.textContent = error.message;
    } finally {
      if (request === controller) refresh.disabled = false;
    }
  }

  async function mutate(route, method, body) {
    if (writing) return;
    writing = true;
    items.inert = true;
    emptyTrash.disabled = true;
    try {
      await api(route, {method, body});
      if (folder.open) await load();
    } catch (error) {
      if (folder.open) {
        if (error.status === 409 && inTrash) await load();
        message.textContent = error.message;
      }
    } finally {
      items.inert = false;
      emptyTrash.disabled = false;
      writing = false;
    }
  }

  async function download(file, control) {
    control.disabled = true;
    try {
      const {ticket} = await api('ticket', {method: 'POST', body: {path: file.path}});
      const url = new URL('file', server);
      url.searchParams.set('ticket', ticket);
      const link = document.createElement('a');
      link.href = url.href;
      link.download = file.name;
      link.referrerPolicy = 'no-referrer';
      document.body.append(link);
      link.click();
      link.remove();
    } catch (error) {
      if (folder.open) message.textContent = error.message;
    } finally {
      control.disabled = false;
    }
  }

  show.addEventListener('click', () => {
    folder.showModal();
    load();
  });
  refresh.addEventListener('click', load);
  search.addEventListener('input', updateItems);
  kind.addEventListener('change', updateItems);
  sort.addEventListener('change', () => {
    if (inTrash) trashSort = sort.value;
    else filesSort = sort.value;
    updateItems();
  });
  toggleTrash.addEventListener('click', () => {
    inTrash = !inTrash;
    search.value = '';
    sort.value = inTrash ? trashSort : filesSort;
    load();
  });
  emptyTrash.addEventListener('click', () => {
    if (trashRevision && window.confirm('Permanently delete every item in Trash?')) {
      mutate('library/trash/all', 'DELETE', {revision: trashRevision});
    }
  });
  document.querySelector('#hide-downloads').addEventListener('click', () => folder.close());
  folder.addEventListener('close', () => {
    if (request) request.abort();
    show.focus();
  });
}
