// Tests for worker/mail/index.js.
// Run: node --test worker/mail/test/mail.test.js (node 20, no install, built-in runner).
// No network: the EMAIL binding is a fake.
import { test } from "node:test";
import assert from "node:assert/strict";
import worker, { hasControlChars, RECIPIENT } from "../index.js";
import { hasControlChars as pagesHasControlChars } from "../../../functions/api/_mail.js";

const FROM = "noreply@sender.example";

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
  return { EMAIL: fakeEmail(), MAIL_FROM: FROM, ...over };
}

const GOOD = { subject: "Contact form: Ada", text: "Hello\nthere", replyTo: "ada@example.com" };

function post(body, { method = "POST", raw } = {}) {
  return new Request("https://mail.invalid/", {
    method,
    headers: { "content-type": "application/json" },
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
  ["soft hyphen", 0xad], ["BOM", 0xfeff],
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

test("ordinary non-ASCII, emoji and the LRM and RLM marks pass in the subject", async () => {
  for (const subject of ["Zoë O'Brien-Smith (R&D)", "Sam \u{1F600}", "a‎b‏c"]) {
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
  const { res, text } = await call(GOOD, { MAIL_FROM: FROM });
  assert.equal(res.status, 502);
  assert.equal(text, "send failed");
});
