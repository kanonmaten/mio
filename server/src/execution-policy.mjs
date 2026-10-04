export class RequestError extends Error {
  constructor(status, code, retryAfter = 60) { super(code); this.status = status; this.code = code; this.retryAfter = retryAfter; }
}

export function awaitWithSignal(promise, signal, discardLateValue) {
  return new Promise((resolve, reject) => {
    const onAbort = () => { signal.removeEventListener('abort', onAbort); reject(signal.reason); };
    if (signal.aborted) onAbort();
    else signal.addEventListener('abort', onAbort, { once: true });
    Promise.resolve(promise).then(value => {
      signal.removeEventListener('abort', onAbort);
      if (signal.aborted) { discardLateValue?.(value); return; }
      resolve(value);
    }, error => {
      signal.removeEventListener('abort', onAbort);
      reject(signal.aborted ? signal.reason : error);
    });
  });
}

export function cancelBody(body) { body?.cancel().catch(() => {}); }
