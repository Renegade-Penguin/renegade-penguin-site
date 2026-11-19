// Tests for functions/api/contact.js and functions/api/_mail.js.
// Run: node --test functions/test/contact.test.js (node 20, no install, built-in runner).
// No network: fetch and the mail adapter are fakes passed in as deps.
import { test } from "node:test";
import assert from "node:assert/strict";
import { handleContact, onRequest } from "../api/contact.js";
import { sendContactMail } from "../api/_mail.js";

const ENV = {
  TURNSTILE_SECRET: "test-secret-value",
  EXPECTED_HOSTNAME: "renegadepenguin.example",
};

const GOOD = {
  name: "Ada Example",
  email: "ada@example.com",
  organization: "Example Org",
  size: "11-50",
  need: "We want a review of our email security.",
  budget: "not-sure",
  timeline: "1-2-months",
  heard: "A conference talk",
  consent: "yes",
  "cf-turnstile-response": "token-abc",
};

function formRequest(fields, { method = "POST", headers = {} } = {}) {
  const body = new URLSearchParams(fields).toString();
  return new Request("https://renegadepenguin.example/api/contact", {
    method,
    headers: { "content-type": "application/x-www-form-urlencoded", ...headers },
    body: method === "GET" || method === "HEAD" ? undefined : body,
  });
}

function turnstileOk(over = {}) {
  return { success: true, hostname: ENV.EXPECTED_HOSTNAME, action: "contact", ...over };
}

// Hand-rolled fake fetch: records calls, answers with the given json (or throws).
// result: an object (200 json), an Error (thrown), { httpStatus: n } (non-ok status) or
// { malformedJson: true } (200 whose body is not json).
function fakeFetch(result) {
  const calls = [];
  const fn = async (url, init) => {
    calls.push({ url, init });
    if (result instanceof Error) throw result;
    if (result && result.httpStatus) return { ok: false, status: result.httpStatus, json: async () => ({}) };
    if (result && result.malformedJson) {
      return { ok: true, status: 200, json: async () => JSON.parse("{not json") };
    }
    return { ok: true, status: 200, json: async () => result };
  };
  fn.calls = calls;
  return fn;
}

function fakeMail(fail) {
  const sent = [];
  const fn = async (env, message) => {
    if (fail) throw fail;
    sent.push({ env, message });
  };
  fn.sent = sent;
  return fn;
}

function deps(result = turnstileOk(), mailFail) {
  const fetch = fakeFetch(result);
  const sendMail = fakeMail(mailFail);
  return { fetch, sendMail };
}

async function run(fields, d = deps(), opts, env = ENV) {
  const res = await handleContact(formRequest(fields, opts), env, d);
  return res;
}

test("rejects non-POST with 405 and an Allow header", async () => {
  const d = deps();
  for (const method of ["GET", "PUT", "DELETE"]) {
    const res = await handleContact(formRequest({}, { method }), ENV, d);
    assert.equal(res.status, 405, method);
    assert.equal(res.headers.get("allow"), "POST");
  }
  assert.equal(d.fetch.calls.length, 0);
  assert.equal(d.sendMail.sent.length, 0);
});

test("rejects an oversize body by content-length with 413", async () => {
  const d = deps();
  const res = await run(GOOD, d, { headers: { "content-length": "20001" } });
  assert.equal(res.status, 413);
  assert.equal(d.sendMail.sent.length, 0);
});

test("rejects an oversize body that has no content-length with 413", async () => {
  const d = deps();
  const big = "need=" + "a".repeat(20001);
  const stream = new ReadableStream({
    start(c) {
      c.enqueue(new TextEncoder().encode(big));
      c.close();
    },
  });
  const req = new Request("https://renegadepenguin.example/api/contact", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: stream,
    duplex: "half",
  });
  const res = await handleContact(req, ENV, d);
  assert.equal(res.status, 413);
  assert.equal(d.sendMail.sent.length, 0);
});

test("a body of exactly 20000 bytes is not rejected for size", async () => {
  const d = deps();
  const pad = "need=" + "a".repeat(20000 - "need=".length);
  const req = new Request("https://renegadepenguin.example/api/contact", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: pad,
  });
  const res = await handleContact(req, ENV, d);
  assert.equal(res.status, 400); // fields missing, but not 413
});

test("a filled honeypot gets 303 to the thanks page and sends nothing", async () => {
  const d = deps();
  const res = await run({ ...GOOD, website: "http://spam.example" }, d);
  assert.equal(res.status, 303);
  assert.equal(res.headers.get("location"), "/contact/thanks/");
  assert.equal(d.sendMail.sent.length, 0);
  assert.equal(d.fetch.calls.length, 0);
});

test("an empty honeypot field does not trigger the trap", async () => {
  const d = deps();
  const res = await run({ ...GOOD, website: "" }, d);
  assert.equal(res.status, 303);
  assert.equal(d.sendMail.sent.length, 1);
});

test("a missing Turnstile token gets 400", async () => {
  const d = deps();
  const { "cf-turnstile-response": _t, ...noToken } = GOOD;
  const res = await run(noToken, d);
  assert.equal(res.status, 400);
  assert.equal(d.fetch.calls.length, 0);
  assert.equal(d.sendMail.sent.length, 0);
});

test("a failed Turnstile verification gets 400", async () => {
  const d = deps({ success: false, "error-codes": ["invalid-input-response"] });
  const res = await run(GOOD, d);
  assert.equal(res.status, 400);
  assert.equal(d.sendMail.sent.length, 0);
});

test("success:false with the correct hostname and action still gets 400", async () => {
  const d = deps(turnstileOk({ success: false }));
  const res = await run(GOOD, d);
  assert.equal(res.status, 400);
  assert.equal(d.sendMail.sent.length, 0);
});

test("a non-ok Turnstile HTTP status gets 502 and sends nothing", async () => {
  const d = deps({ httpStatus: 500 });
  const res = await run(GOOD, d);
  assert.equal(res.status, 502);
  assert.equal(d.sendMail.sent.length, 0);
});

test("a malformed Turnstile json body gets 502 and sends nothing", async () => {
  const d = deps({ malformedJson: true });
  const res = await run(GOOD, d);
  assert.equal(res.status, 502);
  assert.equal(d.sendMail.sent.length, 0);
});

test("a wrong Turnstile hostname gets 400", async () => {
  const d = deps(turnstileOk({ hostname: "evil.example" }));
  const res = await run(GOOD, d);
  assert.equal(res.status, 400);
  assert.equal(d.sendMail.sent.length, 0);
});

test("a wrong Turnstile action gets 400", async () => {
  const d = deps(turnstileOk({ action: "login" }));
  const res = await run(GOOD, d);
  assert.equal(res.status, 400);
  assert.equal(d.sendMail.sent.length, 0);
});

test("a missing Turnstile action gets 400", async () => {
  const d = deps({ success: true, hostname: ENV.EXPECTED_HOSTNAME });
  const res = await run(GOOD, d);
  assert.equal(res.status, 400);
});

test("the siteverify call goes to the Cloudflare endpoint with the secret and token", async () => {
  const d = deps();
  await run(GOOD, d);
  assert.equal(d.fetch.calls.length, 1);
  const { url, init } = d.fetch.calls[0];
  assert.equal(url, "https://challenges.cloudflare.com/turnstile/v0/siteverify");
  assert.equal(init.method, "POST");
  const sent = new URLSearchParams(String(init.body));
  assert.equal(sent.get("secret"), ENV.TURNSTILE_SECRET);
  assert.equal(sent.get("response"), "token-abc");
});

test("an unreachable Turnstile endpoint gets 502 and sends nothing", async () => {
  const d = deps(new Error("network down"));
  const res = await run(GOOD, d);
  assert.equal(res.status, 502);
  assert.equal(d.sendMail.sent.length, 0);
});

test("missing server configuration gets 500 and sends nothing", async () => {
  for (const missing of ["TURNSTILE_SECRET", "EXPECTED_HOSTNAME"]) {
    const d = deps();
    const env = { ...ENV };
    delete env[missing];
    const res = await run(GOOD, d, undefined, env);
    assert.equal(res.status, 500, missing);
    assert.equal(d.sendMail.sent.length, 0);
  }
});

const BAD_FIELDS = [
  ["name missing", { name: "" }],
  ["name blank", { name: "   " }],
  ["name too long", { name: "n".repeat(101) }],
  ["email missing", { email: "" }],
  ["email no at sign", { email: "ada.example.com" }],
  ["email no domain dot", { email: "ada@example" }],
  ["email with a space", { email: "ada lovelace@example.com" }],
  ["email too long", { email: "a".repeat(190) + "@example.com" }],
  ["organization missing", { organization: "" }],
  ["organization too long", { organization: "o".repeat(201) }],
  ["size not an option", { size: "huge" }],
  ["size missing", { size: "" }],
  ["need missing", { need: "" }],
  ["need too long", { need: "x".repeat(4001) }],
  ["budget not an option", { budget: "$1" }],
  ["timeline not an option", { timeline: "yesterday" }],
  ["heard too long", { heard: "h".repeat(201) }],
  ["consent missing", { consent: "" }],
  ["consent wrong value", { consent: "no" }],
];

for (const [label, over] of BAD_FIELDS) {
  test("validation: " + label + " gets 400 with a plain message", async () => {
    const d = deps();
    const res = await run({ ...GOOD, ...over }, d);
    assert.equal(res.status, 400);
    assert.match(res.headers.get("content-type"), /^text\/plain/);
    const text = await res.text();
    assert.ok(text.length > 0 && text.length < 200);
    assert.equal(d.sendMail.sent.length, 0);
    assert.equal(d.fetch.calls.length, 0);
  });
}

test("validation: fields at their exact limits pass", async () => {
  const d = deps();
  const fields = {
    ...GOOD,
    name: "n".repeat(100),
    email: "a".repeat(200 - "@example.com".length) + "@example.com",
    organization: "o".repeat(200),
    need: "x".repeat(4000),
    heard: "h".repeat(200),
  };
  const res = await run(fields, d);
  assert.equal(res.status, 303);
  assert.equal(d.sendMail.sent.length, 1);
});

test("the optional heard field may be empty or absent", async () => {
  const d = deps();
  const { heard: _h, ...noHeard } = GOOD;
  const res = await run(noHeard, d);
  assert.equal(res.status, 303);
});

test("fields are trimmed", async () => {
  const d = deps();
  await run({ ...GOOD, name: "  Ada Example  ", email: "  ada@example.com ", need: "  hello  " }, d);
  const m = d.sendMail.sent[0].message;
  assert.equal(m.replyTo, "ada@example.com");
  assert.match(m.text, /Name: Ada Example\n/);
  assert.match(m.text, /hello/);
  assert.doesNotMatch(m.text, / {2}hello/);
});

// Every control character a header must never carry: C0, DEL, C1, U+2028 and U+2029.
const PROHIBITED = [
  ["NUL", "\u0000"],
  ["tab", "\t"],
  ["LF", "\n"],
  ["vertical tab", "\u000b"],
  ["form feed", "\u000c"],
  ["CR", "\r"],
  ["ESC", "\u001b"],
  ["US", "\u001f"],
  ["DEL", "\u007f"],
  ["C1 start", "\u0080"],
  ["NEL", "\u0085"],
  ["C1 end", "\u009f"],
  ["LINE SEPARATOR", " "],
  ["PARAGRAPH SEPARATOR", " "],
];

test("the prohibited set holds the intended code points (guards against an editor rewriting escapes)", () => {
  assert.deepEqual(
    PROHIBITED.map(([, ch]) => ch.codePointAt(0)),
    [0x0, 0x9, 0xa, 0xb, 0xc, 0xd, 0x1b, 0x1f, 0x7f, 0x80, 0x85, 0x9f, 0x2028, 0x2029],
  );
  for (const [, ch] of PROHIBITED) assert.equal(ch.length, 1);
});

// name and organization go into the subject, email into Reply-To; heard is a single-line field too.
const SINGLE_LINE = {
  name: (c) => "Eve" + c + "Bcc: victim@example.com",
  organization: (c) => "Org" + c + "X",
  heard: (c) => "a" + c + "b",
  email: (c) => "ada" + c + "@example.com",
};

for (const [field, make] of Object.entries(SINGLE_LINE)) {
  for (const [label, ch] of PROHIBITED) {
    test("header safety: " + label + " in " + field + " is rejected with 400", async () => {
      const d = deps();
      const res = await run({ ...GOOD, [field]: make(ch) }, d);
      assert.equal(res.status, 400);
      assert.equal(d.sendMail.sent.length, 0);
      assert.equal(d.fetch.calls.length, 0);
    });
  }
  test("header safety: a control character at the end of " + field + " is rejected, not trimmed", async () => {
    const d = deps();
    const res = await run({ ...GOOD, [field]: make("") + " " }, d);
    assert.equal(res.status, 400);
  });
}

test("header safety: ordinary punctuation and a non-ASCII name still pass", async () => {
  const d = deps();
  const res = await run(
    {
      ...GOOD,
      name: "Zoë O'Brien-Smith, Jr.",
      organization: "R&D (Müller) Ltd. #1",
      email: "z.o+brien_x@example.co.uk",
      heard: "A talk: 50% good, \"great\"",
    },
    d,
  );
  assert.equal(res.status, 303);
  assert.match(d.sendMail.sent[0].message.subject, /Zoë O'Brien-Smith, Jr\./);
  assert.equal(d.sendMail.sent[0].message.replyTo, "z.o+brien_x@example.co.uk");
});

test("a line break inside the need text is kept (it is body text, not a header)", async () => {
  const d = deps();
  await run({ ...GOOD, need: "line one\nline two\ttabbed" }, d);
  assert.match(d.sendMail.sent[0].message.text, /line one\nline two\ttabbed/);
});

test("a valid submission sends one plain text mail and returns 303", async () => {
  const d = deps();
  const res = await run(GOOD, d);
  assert.equal(res.status, 303);
  assert.equal(res.headers.get("location"), "/contact/thanks/");
  assert.equal(d.sendMail.sent.length, 1);
  const { env, message } = d.sendMail.sent[0];
  assert.equal(env, ENV);
  assert.equal(message.replyTo, "ada@example.com");
  assert.match(message.subject, /Ada Example/);
  assert.equal(typeof message.text, "string");
  assert.equal(message.html, undefined);
  for (const needle of ["Ada Example", "ada@example.com", "Example Org", "11-50", "review of our email security", "not-sure", "1-2-months", "A conference talk"]) {
    assert.ok(message.text.includes(needle), needle);
  }
  assert.equal(message.to, undefined, "the recipient is pinned by the adapter, never by the form");
});

test("a mail failure returns 502 and logs no personal data", async () => {
  const logged = [];
  const orig = { error: console.error, log: console.log, warn: console.warn };
  console.error = (...a) => logged.push(a);
  console.log = (...a) => logged.push(a);
  console.warn = (...a) => logged.push(a);
  let res;
  try {
    const failure = new Error("send failed for ada@example.com");
    failure.code = "E_SEND";
    res = await run(GOOD, deps(turnstileOk(), failure));
  } finally {
    Object.assign(console, orig);
  }
  assert.equal(res.status, 502);
  const body = await res.text();
  assert.ok(body.length > 0);
  const dump = JSON.stringify(logged) + body;
  for (const needle of ["ada@example.com", "Ada Example", "Example Org", "email security", "token-abc", ENV.TURNSTILE_SECRET]) {
    assert.ok(!dump.includes(needle), "log or body leaked " + needle);
  }
});

test("onRequest is wired to the handler (GET gives 405)", async () => {
  const res = await onRequest({ request: formRequest({}, { method: "GET" }), env: ENV });
  assert.equal(res.status, 405);
});

// ---- the mail adapter ----

function fakeBinding() {
  const calls = [];
  return { calls, send: async (m) => void calls.push(m) };
}

test("adapter: sends through the EMAIL binding with from and to taken from env", async () => {
  const EMAIL = fakeBinding();
  await sendContactMail(
    { EMAIL, MAIL_FROM: "site@sender.example", MAIL_TO: "inbox@example.com" },
    { subject: "S", text: "T", replyTo: "ada@example.com", to: "attacker@example.com", from: "evil@example.com" },
  );
  assert.equal(EMAIL.calls.length, 1);
  const m = EMAIL.calls[0];
  assert.equal(m.from, "site@sender.example");
  assert.equal(m.to, "inbox@example.com");
  assert.equal(m.subject, "S");
  assert.equal(m.text, "T");
  assert.equal(m.replyTo, "ada@example.com");
});

test("adapter: MAIL_TO defaults to contact@renegadepenguinllc.com", async () => {
  const EMAIL = fakeBinding();
  await sendContactMail({ EMAIL, MAIL_FROM: "site@sender.example" }, { subject: "S", text: "T", replyTo: "a@example.com" });
  assert.equal(EMAIL.calls[0].to, "contact@renegadepenguinllc.com");
});

test("adapter: throws on a prohibited character in any header property and sends nothing", async () => {
  const base = { subject: "S", text: "T", replyTo: "a@example.com" };
  for (const [label, ch] of PROHIBITED) {
    const cases = {
      subject: [{ EMAIL: null, MAIL_FROM: "s@sender.example" }, { ...base, subject: "a" + ch + "b" }],
      replyTo: [{ EMAIL: null, MAIL_FROM: "s@sender.example" }, { ...base, replyTo: "a" + ch + "@example.com" }],
      MAIL_FROM: [{ EMAIL: null, MAIL_FROM: "s" + ch + "@sender.example" }, base],
      MAIL_TO: [{ EMAIL: null, MAIL_FROM: "s@sender.example", MAIL_TO: "i" + ch + "@example.com" }, base],
    };
    for (const [prop, [env, msg]] of Object.entries(cases)) {
      const EMAIL = fakeBinding();
      env.EMAIL = EMAIL;
      await assert.rejects(sendContactMail(env, msg), /invalid header value/, prop + " with " + label);
      assert.equal(EMAIL.calls.length, 0, prop + " with " + label);
    }
  }
});

test("adapter: ordinary punctuation and a non-ASCII subject pass", async () => {
  const EMAIL = fakeBinding();
  await sendContactMail(
    { EMAIL, MAIL_FROM: "site@sender.example" },
    { subject: "Contact form: Zoë O'Brien-Smith (R&D, Ltd.)", text: "T", replyTo: "z.o+brien@example.com" },
  );
  assert.equal(EMAIL.calls.length, 1);
});

test("a bad MAIL_FROM makes the real adapter throw, giving 502 and no mail", async () => {
  const EMAIL = fakeBinding();
  const logged = [];
  const orig = console.error;
  console.error = (...a) => logged.push(a);
  let res;
  try {
    res = await handleContact(
      formRequest(GOOD),
      { ...ENV, EMAIL, MAIL_FROM: "site\u0000@sender.example" },
      { fetch: fakeFetch(turnstileOk()) },
    );
  } finally {
    console.error = orig;
  }
  assert.equal(res.status, 502);
  assert.equal(EMAIL.calls.length, 0);
  assert.ok(!JSON.stringify(logged).includes("ada@example.com"));
});

test("adapter: a missing binding or sender throws", async () => {
  await assert.rejects(sendContactMail({ MAIL_FROM: "s@sender.example" }, { subject: "S", text: "T", replyTo: "a@example.com" }));
  await assert.rejects(sendContactMail({ EMAIL: fakeBinding() }, { subject: "S", text: "T", replyTo: "a@example.com" }));
});
