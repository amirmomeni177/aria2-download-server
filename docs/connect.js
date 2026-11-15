(() => {
  'use strict';

  const endpoint = 'https://ex.mantagheh.com/_aria2/jsonrpc';
  const dialog = document.querySelector('#connect');
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
      dialog.remove();
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
