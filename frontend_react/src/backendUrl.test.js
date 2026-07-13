import { resolveBackendUrl } from './backendUrl';

describe('resolveBackendUrl', () => {
  test('prefers the runtime window._env_ value', () => {
    expect(resolveBackendUrl({ _env_: { BACKEND_URL: 'https://runtime.example' } }, {}))
      .toBe('https://runtime.example');
  });

  test('falls back to the build-time env var', () => {
    expect(resolveBackendUrl(null, { REACT_APP_BACKEND_URL: 'https://buildtime.example' }))
      .toBe('https://buildtime.example');
  });

  test('uses the default when nothing is set', () => {
    expect(resolveBackendUrl(null, {})).toBe('https://backend.acadcart.com');
  });
});
