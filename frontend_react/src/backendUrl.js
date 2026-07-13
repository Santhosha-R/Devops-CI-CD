// Resolve the backend URL: runtime (window._env_, injected per-environment by the container
// entrypoint) first, then a build-time var, then a default. Pure + unit-testable — this is what
// the coverage report exercises.
export function resolveBackendUrl(win, env) {
  return (
    (win && win._env_ && win._env_.BACKEND_URL) ||
    (env && env.REACT_APP_BACKEND_URL) ||
    'https://backend.acadcart.com'
  );
}
