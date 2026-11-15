(() => {
  'use strict';

  const server = 'https://ex.mantagheh.com/_aria2/';
  const endpoint = new URL('jsonrpc', server).href;
  const library = new URL('library', server);
  const dialog = document.querySelector('#connect');
  const workspace = document.querySelector('body > .wrapper');
  const form = dialog.querySelector('form');
  const status = dialog.querySelector('[role=status]');
  const submit = form.querySelector('button');
  const password = form.elements.namedItem('password');
  const username = form.elements.namedItem('username');

  if (window.self !== window.top) {
    form.hidden = true;
    status.textContent = 'Open this page in its own tab to connect.';
    return;
  }

  const basic = (user, pass) => {
    const bytes = new TextEncoder().encode(user + ':' + pass);
    return 'Basic ' + btoa(Array.from(bytes, byte => String.fromCharCode(byte)).join(''));
  };

  function connectFolder(authorization) {
    const folder = document.querySelector('#download-folder');
    const show = document.querySelector('#show-downloads');
    const refresh = document.querySelector('#refresh-downloads');
    const breadcrumbs = document.querySelector('#download-path');
    const items = document.querySelector('#download-items');
    const message = document.querySelector('#download-folder-status');
    const collator = new Intl.Collator(undefined, {numeric: true, sensitivity: 'base'});
    const sizes = new Intl.NumberFormat(undefined, {maximumFractionDigits: 1});
    let currentPath = '';
    let request;

    function formatSize(bytes) {
      const units = ['B', 'KB', 'MB', 'GB', 'TB'];
      let unit = 0;
      while (bytes >= 1024 && unit < units.length - 1) {
        bytes /= 1024;
        unit++;
      }
      return sizes.format(bytes) + ' ' + units[unit];
    }

    function folderLink(name, path) {
      const button = document.createElement('button');
      button.type = 'button';
      button.textContent = name;
      button.addEventListener('click', () => load(path));
      return button;
    }

    function renderPath(path) {
      breadcrumbs.replaceChildren(folderLink('Downloads', ''));
      const parts = path.split('/').filter(Boolean);
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
          breadcrumbs.append(separator, folderLink(name, parts.slice(0, index + 1).join('/')));
        }
      }
    }

    function renderItems(files) {
      files.sort((first, second) => Number(second.folder) - Number(first.folder) || collator.compare(first.name, second.name));
      const rows = document.createDocumentFragment();
      for (const file of files) {
        const item = document.createElement('li');
        const name = file.folder ? folderLink(file.name, file.path) : document.createElement('span');
        const icon = document.createElement('i');
        icon.className = file.folder ? 'fa fa-folder' : 'fa fa-file-o';
        icon.setAttribute('aria-hidden', 'true');
        name.className = 'file-name';
        name.replaceChildren(icon, document.createTextNode(file.name));
        const size = document.createElement('span');
        size.className = 'file-size';
        size.textContent = file.active ? 'In use · ' + formatSize(file.size) : formatSize(file.size);
        item.append(name, size);
        rows.append(item);
      }
      items.replaceChildren(rows);
    }

    async function load(path) {
      if (request) request.abort();
      const controller = new AbortController();
      request = controller;
      currentPath = path;
      renderPath(path);
      items.replaceChildren();
      message.textContent = 'Loading files…';
      refresh.disabled = true;

      try {
        const url = new URL(library);
        if (path) url.searchParams.set('path', path);
        const response = await fetch(url, {
          credentials: 'omit',
          headers: {Authorization: authorization},
          signal: AbortSignal.any([controller.signal, AbortSignal.timeout(15000)])
        });
        if (response.status === 404) throw new Error('This folder is no longer available.');
        if (response.status === 401) throw new Error('Reload the page and sign in again.');
        if (!response.ok) throw new Error('Could not load files. Try refreshing.');
        const {items: files} = await response.json();
        if (controller.signal.aborted) return;
        renderItems(files);
        message.textContent = files.length ? '' : 'This folder is empty.';
      } catch (error) {
        if (!controller.signal.aborted) {
          message.textContent = error instanceof TypeError || error.name === 'TimeoutError'
            ? 'Could not reach the VPS. Try refreshing.'
            : error.message;
        }
      } finally {
        if (request === controller) refresh.disabled = false;
      }
    }

    show.addEventListener('click', () => {
      folder.showModal();
      load(currentPath);
    });
    refresh.addEventListener('click', () => load(currentPath));
    document.querySelector('#hide-downloads').addEventListener('click', () => folder.close());
    folder.addEventListener('close', () => {
      if (request) request.abort();
      show.focus();
    });
  }

  form.addEventListener('submit', async event => {
    event.preventDefault();
    submit.disabled = true;
    status.textContent = 'Connecting…';

    try {
      const authorization = basic(username.value, password.value);
      const response = await fetch(endpoint, {
        method: 'POST',
        credentials: 'omit',
        headers: {Authorization: authorization, 'Content-Type': 'application/json'},
        body: JSON.stringify({jsonrpc: '2.0', id: 'connect', method: 'aria2.getVersion'}),
        signal: AbortSignal.timeout(15000)
      });
      if (response.status === 401) throw new Error('Check your downloader username and password.');
      if (!response.ok || !(await response.json()).result?.version) {
        throw new Error('The downloader did not respond. Try again.');
      }

      angular.module('ariaNg').config(['$provide', '$httpProvider', function ($provide, $httpProvider) {
        $provide.decorator('ariaNgSettingService', ['$delegate', function (settings) {
          const isWebSocket = settings.isCurrentRpcUseWebSocket;
          settings.getCurrentRpcUrl = () => endpoint;
          settings.getCurrentRpcHttpMethod = () => 'POST';
          settings.getCurrentRpcRequestHeaders = () => '';
          settings.getCurrentRpcSecret = () => '';
          settings.isCurrentRpcUseWebSocket = protocol => protocol ? isWebSocket(protocol) : false;
          return settings;
        }]);
        $httpProvider.interceptors.push(function () {
          return {
            request(config) {
              if (config.url === endpoint && config.method === 'POST') {
                config.headers.Authorization = authorization;
              }
              return config;
            }
          };
        });
      }]);
      password.value = '';
      angular.bootstrap(document.documentElement, ['ariaNg']);
      connectFolder(authorization);
      document.body.classList.remove('landing-open');
      workspace.inert = false;
      workspace.removeAttribute('aria-hidden');
      dialog.remove();
      document.querySelector('#show-downloads').focus();
    } catch (error) {
      status.textContent = error instanceof TypeError || error.name === 'TimeoutError'
        ? 'Could not connect to the VPS. Try again.'
        : error.message;
      password.focus();
    } finally {
      submit.disabled = false;
    }
  });
})();
