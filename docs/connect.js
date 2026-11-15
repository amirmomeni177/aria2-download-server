import {connectFolder} from './files.js?v=3';

(() => {
  'use strict';

  const server = 'https://ex.mantagheh.com/_aria2/';
  const endpoint = new URL('jsonrpc', server).href;
  const storageKey = 'aria2-pages-remember-v1';
  const tokenPattern = /^[A-Za-z0-9_-]{43}$/;
  const dialog = document.querySelector('#connect');
  const workspace = document.querySelector('body > .wrapper');
  const form = dialog.querySelector('form');
  const status = dialog.querySelector('[role=status]');
  const submit = form.querySelector('button');
  const password = form.elements.namedItem('password');
  const username = form.elements.namedItem('username');
  const remember = form.elements.namedItem('remember');

  if (window.self !== window.top) {
    form.hidden = true;
    status.textContent = 'Open this page in its own tab to connect.';
    return;
  }

  const basic = (user, pass) => {
    const bytes = new TextEncoder().encode(user + ':' + pass);
    return 'Basic ' + btoa(Array.from(bytes, byte => String.fromCharCode(byte)).join(''));
  };

  function forget() {
    try { localStorage.removeItem(storageKey); } catch {}
  }

  async function request(authorization, path, {method = 'GET', body, signal = AbortSignal.timeout(15000)} = {}) {
    const headers = {Authorization: authorization};
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    let response;
    try {
      response = await fetch(new URL(path, server), {
        method,
        credentials: 'omit',
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal
      });
    } catch {
      throw new Error('Could not connect to the VPS. Try again.');
    }
    const result = await response.json().catch(() => ({}));
    if (!response.ok) {
      const error = new Error(result.message || 'The downloader could not complete this request.');
      error.status = response.status;
      throw error;
    }
    return result;
  }

  async function checkConnection(authorization) {
    const result = await request(authorization, endpoint, {
      method: 'POST',
      body: {jsonrpc: '2.0', id: 'connect', method: 'aria2.getVersion'}
    });
    if (!result.result?.version) throw new Error('The downloader did not respond. Try again.');
  }

  function startApp(authorization, token) {
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
            if (config.url === endpoint && config.method === 'POST') config.headers.Authorization = authorization;
            return config;
          }
        };
      });
    }]);
    password.value = '';
    angular.bootstrap(document.documentElement, ['ariaNg']);
    connectFolder((path, options) => request(authorization, path, options), server);
    const signOut = document.querySelector('#sign-out');
    signOut.addEventListener('click', async () => {
      signOut.disabled = true;
      forget();
      if (token) {
        try {
          await request(authorization, 'signout', {method: 'DELETE', signal: AbortSignal.timeout(3500)});
        } catch {}
      }
      window.location.reload();
    });
    if (token) {
      window.addEventListener('storage', event => {
        if (event.key === storageKey && event.oldValue === token && !event.newValue) window.location.reload();
      });
    }
    document.body.classList.remove('landing-open');
    workspace.inert = false;
    workspace.removeAttribute('aria-hidden');
    dialog.remove();
    document.querySelector('#show-downloads').focus();
  }

  async function resume() {
    let token;
    try { token = localStorage.getItem(storageKey); } catch { return; }
    if (!tokenPattern.test(token || '')) return;

    submit.disabled = true;
    status.textContent = 'Reconnecting…';
    try {
      const authorization = 'Bearer ' + token;
      await checkConnection(authorization);
      startApp(authorization, token);
    } catch (error) {
      if (error.status === 401) {
        forget();
        status.textContent = 'Your saved sign-in expired. Sign in again.';
      } else {
        status.textContent = error.message;
      }
    } finally {
      submit.disabled = false;
    }
  }

  form.addEventListener('submit', async event => {
    event.preventDefault();
    submit.disabled = true;
    status.textContent = 'Connecting…';

    try {
      let authorization = basic(username.value, password.value);
      await checkConnection(authorization);
      let token;
      if (remember.checked) {
        ({token} = await request(authorization, 'session', {method: 'POST'}));
        if (!tokenPattern.test(token || '')) throw new Error('Could not save this sign-in. Try again.');
        authorization = 'Bearer ' + token;
        try {
          localStorage.setItem(storageKey, token);
        } catch {
          request(authorization, 'signout', {method: 'DELETE'}).catch(() => {});
          throw new Error('Browser storage is unavailable. Uncheck Remember me to sign in.');
        }
      } else {
        forget();
      }
      startApp(authorization, token);
    } catch (error) {
      status.textContent = error.status === 401 ? 'Check your downloader username and password.' : error.message;
      password.focus();
    } finally {
      submit.disabled = false;
    }
  });

  resume();
})();
