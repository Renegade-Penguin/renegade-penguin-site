// Tests for worker/mail/index.js.
// Run: node --test worker/mail/test/mail.test.js (node 20, no install, built-in runner).
// No network: the EMAIL binding is a fake.
import { test } from "node:test";
import assert from "node:assert/strict";
import worker, { hasControlChars, RECIPIENT } from "../index.js";
import { hasControlChars as pagesHasControlChars } from "../../../functions/api/_mail.js";

const FROM = "noreply@sender.example";
const SECRET = "worker-test-secret";

function fakeEmail(fail) {
  const calls = [];
  return {
    calls,
    send: async (m) => {
      if (fail) throw fail;
      calls.push(m);
    },
  };
}

function env(over = {}) {
  return { EMAIL: fakeEmail(), MAIL_FROM: FROM, MAIL_SHARED_SECRET: SECRET, ...over };
}

const GOOD = { subject: "Contact form: Ada", text: "Hello\nthere", replyTo: "ada@example.com" };

function post(body, { method = "POST", raw, headers } = {}) {
  return new Request("https://mail.invalid/", {
    method,
    headers: { "content-type": "application/json", "x-mail-auth": SECRET, ...headers },
    body: method === "GET" || method === "HEAD" ? undefined : raw !== undefined ? raw : JSON.stringify(body),
  });
}

async function call(body, e = env(), opts) {
  const res = await worker.fetch(post(body, opts), e);
  return { res, text: await res.text(), e };
}

// ---- method and body ----

test("non-POST methods get 405 with a fixed body and nothing is sent", async () => {
  for (const method of ["GET", "PUT", "DELETE", "PATCH", "HEAD"]) {
    const e = env();
    const res = await worker.fetch(post(GOOD, { method }), e);
    assert.equal(res.status, 405, method);
    assert.equal(e.EMAIL.calls.length, 0);
  }
  const { text } = await call(GOOD, env(), { method: "GET" });
  assert.equal(text, "method not allowed");
});

test("a body that is not a JSON object gets 400 and nothing is sent", async () => {
  for (const raw of ["", "{not json", "null", "[]", "42", '"str"']) {
    const { res, text, e } = await call(null, env(), { raw });
    assert.equal(res.status, 400, JSON.stringify(raw));
    assert.equal(text, "bad request");
    assert.equal(e.EMAIL.calls.length, 0);
  }
});

test("missing or non-string fields get 400", async () => {
  for (const key of Object.keys(GOOD)) {
    for (const bad of [undefined, null, 5, {}, [], ""]) {
      const body = { ...GOOD, [key]: bad };
      const { res, e } = await call(body);
      assert.equal(res.status, 400, key + " = " + JSON.stringify(bad));
      assert.equal(e.EMAIL.calls.length, 0);
    }
  }
});

test("a valid request sends once and returns 200", async () => {
  const { res, e } = await call(GOOD);
  assert.equal(res.status, 200);
  assert.equal(e.EMAIL.calls.length, 1);
  assert.deepEqual(e.EMAIL.calls[0], {
    from: FROM,
    to: "contact@renegadepenguinllc.com",
    subject: GOOD.subject,
    text: GOOD.text,
    replyTo: GOOD.replyTo,
  });
});

// ---- rejected characters ----

const PROHIBITED = [
  ["NUL", 0x0], ["tab", 0x9], ["LF", 0xa], ["CR", 0xd], ["ESC", 0x1b], ["US", 0x1f],
  ["DEL", 0x7f], ["C1 start", 0x80], ["NEL", 0x85], ["C1 end", 0x9f],
  ["soft hyphen", 0xad], ["ALM", 0x61c], ["LRM", 0x200e], ["RLM", 0x200f], ["BOM", 0xfeff],
  ["LINE SEPARATOR", 0x2028], ["PARAGRAPH SEPARATOR", 0x2029],
  ["LRE", 0x202a], ["RLE", 0x202b], ["PDF", 0x202c], ["LRO", 0x202d], ["RLO", 0x202e],
  ["LRI", 0x2066], ["RLI", 0x2067], ["FSI", 0x2068], ["PDI", 0x2069],
  ["lone high surrogate", 0xd800], ["lone low surrogate", 0xdc00], ["last surrogate", 0xdfff],
].map(([label, cp]) => [label, String.fromCharCode(cp)]);

test("each prohibited character class is rejected in subject and replyTo", async () => {
  assert.ok(PROHIBITED.length > 0);
  for (const [label, ch] of PROHIBITED) {
    // JSON.stringify escapes lone surrogates, so the Worker sees them after parsing.
    for (const body of [
      { ...GOOD, subject: "a" + ch + "b" },
      { ...GOOD, replyTo: "a" + ch + "@example.com" },
    ]) {
      const { res, text, e } = await call(body);
      assert.equal(res.status, 400, label);
      assert.equal(text, "bad request");
      assert.equal(e.EMAIL.calls.length, 0, label);
    }
  }
});

test("ordinary non-ASCII, emoji and right-to-left letters pass in the subject", async () => {
  for (const subject of ["Zoë O'Brien-Smith (R&D)", "Sam \u{1F600}", "שלום כהן", "محمد علي"]) {
    const { res, e } = await call({ ...GOOD, subject });
    assert.equal(res.status, 200, subject);
    assert.equal(e.EMAIL.calls[0].subject, subject);
  }
});

test("line breaks in the text body are allowed", async () => {
  const { res, e } = await call({ ...GOOD, text: "one\r\ntwo\n\nthree\ttab" });
  assert.equal(res.status, 200);
  assert.equal(e.EMAIL.calls[0].text, "one\r\ntwo\n\nthree\ttab");
});

// ---- the two copies of the control character rule ----

test("hasControlChars is identical to the copy in functions/api/_mail.js", () => {
  assert.equal(hasControlChars.toString(), pagesHasControlChars.toString());
  for (let cp = 0; cp <= 0xffff; cp++) {
    const ch = String.fromCharCode(cp);
    assert.equal(hasControlChars(ch), pagesHasControlChars(ch), "U+" + cp.toString(16));
  }
  assert.equal(hasControlChars("fine"), false);
  assert.equal(hasControlChars("a\nb"), true);
  for (const cp of [0x61c, 0x200e, 0x200f]) {
    assert.equal(hasControlChars("a" + String.fromCharCode(cp)), true);
    assert.equal(pagesHasControlChars("a" + String.fromCharCode(cp)), true);
  }
});

// ---- length limits ----

test("length limits: subject 200, replyTo 200, text 20000", async () => {
  const okSubject = "s".repeat(200);
  const okText = "t".repeat(20000);
  const okReply = "a".repeat(200 - "@example.com".length) + "@example.com";
  assert.equal(okReply.length, 200);
  assert.equal((await call({ subject: okSubject, text: okText, replyTo: okReply })).res.status, 200);

  const over = [
    { ...GOOD, subject: "s".repeat(201) },
    { ...GOOD, text: "t".repeat(20001) },
    { ...GOOD, replyTo: "a".repeat(201 - "@example.com".length) + "@example.com" },
  ];
  for (const body of over) {
    const { res, e } = await call(body);
    assert.equal(res.status, 400);
    assert.equal(e.EMAIL.calls.length, 0);
  }
});

test("replyTo must look like one email address", async () => {
  for (const replyTo of ["nope", "a@b", "@example.com", "a@", "a b@example.com", "a@example.com, b@example.com", "A <a@example.com>", "a@@example.com"]) {
    const { res, e } = await call({ ...GOOD, replyTo });
    assert.equal(res.status, 400, replyTo);
    assert.equal(e.EMAIL.calls.length, 0);
  }
  for (const replyTo of ["a@example.com", "z.o+brien@mail.example.org"]) {
    assert.equal((await call({ ...GOOD, replyTo })).res.status, 200, replyTo);
  }
});

// ---- recipient and sender ----

test("the recipient is fixed whatever the request says", async () => {
  assert.equal(RECIPIENT, "contact@renegadepenguinllc.com");
  const e = env();
  await call({ ...GOOD, to: "attacker@example.com", recipient: "x@example.com", cc: "y@example.com", bcc: "z@example.com" }, e);
  assert.equal(e.EMAIL.calls.length, 1);
  assert.equal(e.EMAIL.calls[0].to, "contact@renegadepenguinllc.com");
  assert.deepEqual(Object.keys(e.EMAIL.calls[0]).sort(), ["from", "replyTo", "subject", "text", "to"]);
});

test("the sender comes only from MAIL_FROM", async () => {
  const e = env({ MAIL_FROM: "site@other.example" });
  await call({ ...GOOD, from: "evil@example.com", sender: "evil@example.com" }, e);
  assert.equal(e.EMAIL.calls[0].from, "site@other.example");
});

test("a missing or bad MAIL_FROM gives a generic 502 and sends nothing", async () => {
  for (const MAIL_FROM of [undefined, "", "bad\nfrom@example.com"]) {
    const e = env({ MAIL_FROM });
    const { res, text } = await call(GOOD, e);
    assert.equal(res.status, 502);
    assert.equal(text, "send failed");
    assert.equal(e.EMAIL.calls.length, 0);
  }
});

// ---- failure ----

test("a send failure gives a generic 502 that echoes nothing", async () => {
  const secret = "ada-secret-detail@example.com";
  const e = env({ EMAIL: fakeEmail(new Error("provider said no for " + secret)) });
  const { res, text } = await call({ ...GOOD, replyTo: secret, subject: "Subject-marker", text: "Body-marker" }, e);
  assert.equal(res.status, 502);
  assert.equal(text, "send failed");
  for (const s of [secret, "Subject-marker", "Body-marker", "provider"]) assert.ok(!text.includes(s));
});

test("a missing EMAIL binding gives a generic 502", async () => {
  const { res, text } = await call(GOOD, { MAIL_FROM: FROM, MAIL_SHARED_SECRET: SECRET });
  assert.equal(res.status, 502);
  assert.equal(text, "send failed");
});

// ---- shared secret ----

test("the shared secret header is required and is checked before the body is read", async () => {
  for (const headers of [{ "x-mail-auth": "" }, { "x-mail-auth": "wrong" }, { "x-mail-auth": SECRET + "x" }, { "x-mail-auth": SECRET.slice(1) }]) {
    const e = env();
    const res = await worker.fetch(post(GOOD, { headers }), e);
    assert.equal(res.status, 401, JSON.stringify(headers));
    assert.equal(await res.text(), "unauthorized");
    assert.equal(e.EMAIL.calls.length, 0);
  }
  const e = env();
  const noHeader = new Request("https://mail.invalid/", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(GOOD),
  });
  assert.equal((await worker.fetch(noHeader, e)).status, 401);
  // A bad body with a wrong secret is 401, not 400: the secret comes first.
  const bad = await worker.fetch(post(null, { raw: "{not json", headers: { "x-mail-auth": "wrong" } }), env());
  assert.equal(bad.status, 401);
  // The body stream is never pulled when the secret is wrong.
  let pulled = false;
  const body = new ReadableStream({
    pull(c) {
      pulled = true;
      c.enqueue(new Uint8Array(1));
    },
  }, { highWaterMark: 0 }); // no eager pull when the Request is built
  const r2 = new Request("https://mail.invalid/", {
    method: "POST",
    headers: { "content-type": "application/json", "x-mail-auth": "wrong" },
    body,
    duplex: "half",
  });
  assert.equal((await worker.fetch(r2, env())).status, 401);
  assert.equal(pulled, false);
});

test("an unset or empty MAIL_SHARED_SECRET fails closed with 401 for every request", async () => {
  for (const MAIL_SHARED_SECRET of [undefined, "", null]) {
    for (const headers of [{ "x-mail-auth": "" }, { "x-mail-auth": "undefined" }, { "x-mail-auth": "null" }]) {
      const e = env({ MAIL_SHARED_SECRET });
      const res = await worker.fetch(post(GOOD, { headers }), e);
      assert.equal(res.status, 401);
      assert.equal(e.EMAIL.calls.length, 0);
    }
  }
});

test("a wrong secret on a non-POST is 401 (auth first)", async () => {
  const res = await worker.fetch(post(GOOD, { method: "GET", headers: { "x-mail-auth": "wrong" } }), env());
  assert.equal(res.status, 401);
});

// ---- content type ----

test("only application/json is accepted", async () => {
  for (const ct of ["text/plain", "application/x-www-form-urlencoded", "application/jsonx", "text/json"]) {
    const e = env();
    const res = await worker.fetch(post(GOOD, { headers: { "content-type": ct } }), e);
    assert.equal(res.status, 415, ct);
    assert.equal(e.EMAIL.calls.length, 0);
  }
  for (const ct of ["application/json", "application/json; charset=utf-8", "Application/JSON"]) {
    assert.equal((await worker.fetch(post(GOOD, { headers: { "content-type": ct } }), env())).status, 200, ct);
  }
});

// ---- bounded body read ----

const MAX_BODY = 3 * (20000 + 200 + 200);

function streamRequest({ chunks, chunkSize, headers }) {
  const state = { produced: 0, cancelled: false };
  const body = new ReadableStream({
    pull(controller) {
      if (state.produced >= chunks) return controller.close();
      state.produced++;
      controller.enqueue(new Uint8Array(chunkSize).fill(0x20));
    },
    cancel() {
      state.cancelled = true;
    },
  }, { highWaterMark: 0 }); // no eager pull when the Request is built
  const req = new Request("https://mail.invalid/", {
    method: "POST",
    headers: { "content-type": "application/json", "x-mail-auth": SECRET, ...headers },
    body,
    duplex: "half",
  });
  return { req, state };
}

test("an oversized Content-Length is rejected before any body read", async () => {
  const { req, state } = streamRequest({ chunks: 5, chunkSize: 1024, headers: { "content-length": String(MAX_BODY + 1) } });
  const res = await worker.fetch(req, env());
  assert.equal(res.status, 413);
  assert.equal(state.produced, 0);
});

test("reading stops at the limit when Content-Length is missing or lies", async () => {
  for (const headers of [{}, { "content-length": "10" }]) {
    const chunkSize = 4096;
    const { req, state } = streamRequest({ chunks: 1000, chunkSize, headers });
    const res = await worker.fetch(req, env());
    assert.equal(res.status, 413, JSON.stringify(headers));
    assert.equal(state.cancelled, true);
    assert.ok(state.produced <= Math.ceil(MAX_BODY / chunkSize) + 3, "produced " + state.produced);
  }
});

test("a streamed body within the limit is parsed", async () => {
  const bytes = new TextEncoder().encode(JSON.stringify(GOOD));
  const body = new ReadableStream({
    start(c) {
      c.enqueue(bytes.slice(0, 5));
      c.enqueue(bytes.slice(5));
      c.close();
    },
  });
  const req = new Request("https://mail.invalid/", {
    method: "POST",
    headers: { "content-type": "application/json", "x-mail-auth": SECRET },
    body,
    duplex: "half",
  });
  const e = env();
  assert.equal((await worker.fetch(req, e)).status, 200);
  assert.equal(e.EMAIL.calls.length, 1);
});
