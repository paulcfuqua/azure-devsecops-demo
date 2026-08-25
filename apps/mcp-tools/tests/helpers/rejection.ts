/**
 * `await rejection(promise)` — get the error a promise rejected with, typed.
 *
 * `promise.catch((e) => e as AdapterError)` widens to `T | AdapterError`, so
 * every assertion on `.kind` or `.message` then needs a cast. This gives the
 * error back narrowed, and fails loudly if the call unexpectedly SUCCEEDED —
 * which `.catch()` silently would not.
 */
export async function rejection<E = Error>(promise: Promise<unknown>): Promise<E> {
  let caught: { threw: false } | { threw: true; error: unknown } = { threw: false };
  try {
    await promise;
  } catch (error) {
    caught = { threw: true, error };
  }
  if (!caught.threw) throw new Error("expected the call to reject, but it resolved");
  return caught.error as E;
}
