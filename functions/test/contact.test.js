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

test("a non-ok Turnstile HTTP status gets 424 and sends nothing", async () => {
  const d = deps({ httpStatus: 500 });
  const res = await run(GOOD, d);
  assert.equal(res.status, 424);
  assert.equal(d.sendMail.sent.length, 0);
});

test("a malformed Turnstile json body gets 424 and sends nothing", async () => {
  const d = deps({ malformedJson: true });
  const res = await run(GOOD, d);
  assert.equal(res.status, 424);
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

test("an unreachable Turnstile endpoint gets 424 and sends nothing", async () => {
  const d = deps(new Error("network down"));
  const res = await run(GOOD, d);
  assert.equal(res.status, 424);
  assert.equal(d.sendMail.sent.length, 0);
});

test("missing server configuration gets 424 and sends nothing", async () => {
  for (const missing of ["TURNSTILE_SECRET", "EXPECTED_HOSTNAME"]) {
    const d = deps();
    const env = { ...ENV };
    delete env[missing];
    const res = await run(GOOD, d, undefined, env);
    assert.equal(res.status, 424, missing);
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
  ["soft hyphen", String.fromCharCode(0xad)],
  ["ALM", String.fromCharCode(0x61c)],
  ["LRM", String.fromCharCode(0x200e)],
  ["RLM", String.fromCharCode(0x200f)],
  ["BOM / zero width no-break space", String.fromCharCode(0xfeff)],
  ["LRE", String.fromCharCode(0x202a)],
  ["RLE", String.fromCharCode(0x202b)],
  ["PDF", String.fromCharCode(0x202c)],
  ["LRO", String.fromCharCode(0x202d)],
  ["RLO", String.fromCharCode(0x202e)],
  ["LRI", String.fromCharCode(0x2066)],
  ["RLI", String.fromCharCode(0x2067)],
  ["FSI", String.fromCharCode(0x2068)],
  ["PDI", String.fromCharCode(0x2069)],
  ["LINE SEPARATOR", " "],
  ["PARAGRAPH SEPARATOR", " "],
];

test("the prohibited set holds the intended code points (guards against an editor rewriting escapes)", () => {
  assert.deepEqual(
    PROHIBITED.map(([, ch]) => ch.codePointAt(0)),
    [
      0x0, 0x9, 0xa, 0xb, 0xc, 0xd, 0x1b, 0x1f, 0x7f, 0x80, 0x85, 0x9f, 0xad, 0x61c, 0x200e, 0x200f, 0xfeff,
      0x202a, 0x202b, 0x202c, 0x202d, 0x202e, 0x2066, 0x2067, 0x2068, 0x2069, 0x2028, 0x2029,
    ],
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

// Ordinary non-ASCII names, including right-to-left scripts, are not control characters and must
// keep passing. The direction marks U+200E, U+200F and U+061C are rejected (see PROHIBITED).
const GOOD_NAMES = [
  "Zoë Müller",
  "Søren Ångström",
  "Мария Иванова",
  "李雷",
  "José Núñez-Ortiz",
  "שלום כהן",
  "محمد علي",
  "Nazanin" + String.fromCharCode(0x200c) + "Zahra",
];

for (const nm of GOOD_NAMES) {
  test("header safety: the name " + JSON.stringify(nm) + " still passes", async () => {
    const d = deps();
    const res = await run({ ...GOOD, name: nm }, d);
    assert.equal(res.status, 303);
    assert.ok(d.sendMail.sent[0].message.subject.includes(nm));
  });
}

test("a lone surrogate in any header property throws in the adapter", async () => {
  const base = { subject: "S", text: "T", replyTo: "a@example.com" };
  for (const lone of [String.fromCharCode(0xd800), String.fromCharCode(0xdc00), String.fromCharCode(0xdfff)]) {
    for (const msg of [{ ...base, subject: "a" + lone }, { ...base, replyTo: lone + "@example.com" }]) {
      const MAIL_WORKER = fakeBinding();
      await assert.rejects(sendContactMail({ MAIL_WORKER, MAIL_SHARED_SECRET: SECRET, MAIL_FROM: "s@sender.example" }, msg), /invalid header value/);
      assert.equal(MAIL_WORKER.calls.length, 0);
    }
  }
  // A valid surrogate pair (an emoji in a name) is a real character and passes.
  const MAIL_WORKER = fakeBinding();
  await sendContactMail({ MAIL_WORKER, MAIL_SHARED_SECRET: SECRET, MAIL_FROM: "s@sender.example" }, { ...base, subject: "Sam \u{1F600}" });
  assert.equal(MAIL_WORKER.calls.length, 1);
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

test("a mail failure returns 424 and logs no personal data", async () => {
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
  assert.equal(res.status, 424);
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

const SECRET = "test-shared-secret-value";

// Fake service binding: fetch(request) records the parsed JSON body and answers with `status`.
function fakeBinding(status = 200) {
  const calls = [];
  const requests = [];
  return {
    calls,
    requests,
    fetch: async (req) => {
      requests.push({
        url: req.url,
        method: req.method,
        contentType: req.headers.get("content-type"),
        auth: req.headers.get("x-mail-auth"),
      });
      calls.push(JSON.parse(await req.text()));
      return new Response("ok", { status });
    },
  };
}

test("adapter: posts JSON to the MAIL_WORKER service binding and sends no from or to", async () => {
  const MAIL_WORKER = fakeBinding();
  await sendContactMail(
    { MAIL_WORKER, MAIL_SHARED_SECRET: SECRET, MAIL_FROM: "site@sender.example", MAIL_TO: "inbox@example.com" },
    { subject: "S", text: "T", replyTo: "ada@example.com", to: "attacker@example.com", from: "evil@example.com" },
  );
  assert.equal(MAIL_WORKER.calls.length, 1);
  const m = MAIL_WORKER.calls[0];
  assert.deepEqual(Object.keys(m).sort(), ["replyTo", "subject", "text"]);
  assert.deepEqual(MAIL_WORKER.requests[0], {
    url: "https://mail.invalid/",
    method: "POST",
    contentType: "application/json",
    auth: SECRET,
  });
  assert.equal(m.subject, "S");
  assert.equal(m.text, "T");
  assert.equal(m.replyTo, "ada@example.com");
});

test("adapter: a non-2xx answer from the Worker throws and the message is not echoed", async () => {
  const MAIL_WORKER = fakeBinding(502);
  await assert.rejects(
    sendContactMail({ MAIL_WORKER, MAIL_SHARED_SECRET: SECRET, MAIL_FROM: "site@sender.example" }, { subject: "S", text: "T", replyTo: "a@example.com" }),
    (e) => /status 502/.test(e.message) && !e.message.includes("a@example.com"),
  );
});

test("adapter: a rejected fetch propagates", async () => {
  const MAIL_WORKER = { fetch: async () => { throw new Error("boom"); } };
  await assert.rejects(
    sendContactMail({ MAIL_WORKER, MAIL_SHARED_SECRET: SECRET, MAIL_FROM: "site@sender.example" }, { subject: "S", text: "T", replyTo: "a@example.com" }),
    /boom/,
  );
});

test("adapter: throws on a prohibited character in any header property and sends nothing", async () => {
  const base = { subject: "S", text: "T", replyTo: "a@example.com" };
  for (const [label, ch] of PROHIBITED) {
    const cases = {
      subject: [{ MAIL_FROM: "s@sender.example" }, { ...base, subject: "a" + ch + "b" }],
      replyTo: [{ MAIL_FROM: "s@sender.example" }, { ...base, replyTo: "a" + ch + "@example.com" }],
      MAIL_FROM: [{ MAIL_FROM: "s" + ch + "@sender.example" }, base],
      MAIL_TO: [{ MAIL_FROM: "s@sender.example", MAIL_TO: "i" + ch + "@example.com" }, base],
    };
    for (const [prop, [env, msg]] of Object.entries(cases)) {
      const MAIL_WORKER = fakeBinding();
      env.MAIL_WORKER = MAIL_WORKER;
      env.MAIL_SHARED_SECRET = SECRET;
      await assert.rejects(sendContactMail(env, msg), /invalid header value/, prop + " with " + label);
      assert.equal(MAIL_WORKER.calls.length, 0, prop + " with " + label);
    }
  }
});

test("adapter: ordinary punctuation and a non-ASCII subject pass", async () => {
  const MAIL_WORKER = fakeBinding();
  await sendContactMail(
    { MAIL_WORKER, MAIL_SHARED_SECRET: SECRET, MAIL_FROM: "site@sender.example" },
    { subject: "Contact form: Zoë O'Brien-Smith (R&D, Ltd.)", text: "T", replyTo: "z.o+brien@example.com" },
  );
  assert.equal(MAIL_WORKER.calls.length, 1);
});

test("a bad MAIL_FROM makes the real adapter throw, giving 424 and no mail", async () => {
  const MAIL_WORKER = fakeBinding();
  const logged = [];
  const orig = console.error;
  console.error = (...a) => logged.push(a);
  let res;
  try {
    res = await handleContact(
      formRequest(GOOD),
      { ...ENV, MAIL_WORKER, MAIL_SHARED_SECRET: SECRET, MAIL_FROM: "site\u0000@sender.example" },
      { fetch: fakeFetch(turnstileOk()) },
    );
  } finally {
    console.error = orig;
  }
  assert.equal(res.status, 424);
  assert.equal(MAIL_WORKER.calls.length, 0);
  assert.ok(!JSON.stringify(logged).includes("ada@example.com"));
});

test("adapter: a missing binding or sender throws", async () => {
  await assert.rejects(sendContactMail({ MAIL_FROM: "s@sender.example" }, { subject: "S", text: "T", replyTo: "a@example.com" }));
  await assert.rejects(sendContactMail({ MAIL_WORKER: fakeBinding() }, { subject: "S", text: "T", replyTo: "a@example.com" }));
});

test("adapter: refuses without MAIL_SHARED_SECRET and sends nothing", async () => {
  for (const MAIL_SHARED_SECRET of [undefined, "", null]) {
    const MAIL_WORKER = fakeBinding();
    await assert.rejects(
      sendContactMail({ MAIL_WORKER, MAIL_SHARED_SECRET, MAIL_FROM: "s@sender.example" }, { subject: "S", text: "T", replyTo: "a@example.com" }),
      (e) => /MAIL_SHARED_SECRET is not configured/.test(e.message),
    );
    assert.equal(MAIL_WORKER.calls.length, 0);
  }
});

// Cloudflare replaces 5xx responses with its own error page, so visitors would never see the
// fallback address. Every failure path answers with a non-5xx HTML page that carries it.
const FALLBACK = "contact@renegadepenguinllc.com";

async function failurePaths() {
  const quiet = console.error;
  console.error = () => {};
  try {
    const noSecret = { ...ENV };
    delete noSecret.TURNSTILE_SECRET;
    return {
      "config incomplete": await run(GOOD, deps(), undefined, noSecret),
      "spam check unreachable": await run(GOOD, deps(new Error("network down"))),
      "mail send failed": await run(GOOD, deps(turnstileOk(), new Error("boom"))),
    };
  } finally {
    console.error = quiet;
  }
}

test("every failure path returns a non-5xx HTML page with the fallback address", async () => {
  const paths = await failurePaths();
  assert.equal(Object.keys(paths).length, 3);
  for (const [name, res] of Object.entries(paths)) {
    assert.equal(res.status, 424, name);
    assert.ok(res.status < 500 || res.status > 599, name);
    assert.match(res.headers.get("content-type"), /^text\/html; charset=utf-8$/i, name);
    const body = await res.text();
    assert.ok(body.includes(FALLBACK), name);
    assert.ok(body.includes('href="mailto:' + FALLBACK + '"'), name);
    assert.ok(body.includes('href="/contact/"'), name);
    assert.ok(!body.includes("ada@example.com") && !body.includes("Ada Example"), name);
  }
});

// Pages Function responses do not get the static _headers file, so every response carries its own set.
import { createHash } from "node:crypto";

function missingHeaders(res) {
  const out = [];
  const h = (n) => res.headers.get(n);
  if (h("x-content-type-options") !== "nosniff") out.push("x-content-type-options");
  if (h("referrer-policy") !== "same-origin") out.push("referrer-policy");
  if (h("cache-control") !== "no-store") out.push("cache-control");
  if (/^text\/html/i.test(h("content-type") ?? "")) {
    const csp = h("content-security-policy") ?? "";
    for (const d of ["default-src 'none'", "frame-ancestors 'none'", "base-uri 'none'", "form-action 'none'"]) {
      if (!csp.includes(d)) out.push("csp:" + d);
    }
    if (/unsafe-inline|unsafe-eval|script-src/.test(csp)) out.push("csp:too-loose");
  }
  return out;
}

async function allResponsePaths() {
  const quiet = console.error;
  console.error = () => {};
  try {
    return {
      ...(await failurePaths()),
      "405": await handleContact(formRequest({}, { method: "GET" }), ENV, deps()),
      "413": await run(GOOD, deps(), { headers: { "content-length": "20001" } }),
      "400 validation": await run({ ...GOOD, name: "" }),
      "400 no token": await run({ ...GOOD, "cf-turnstile-response": "" }),
      "400 failed spam check": await run(GOOD, deps(turnstileOk({ success: false }))),
      "303 honeypot": await run({ ...GOOD, website: "x" }),
      "303 success": await run(GOOD),
    };
  } finally {
    console.error = quiet;
  }
}

test("every response path carries the full security header set", async () => {
  const paths = await allResponsePaths();
  assert.equal(Object.keys(paths).length, 10);
  for (const [name, res] of Object.entries(paths)) {
    assert.deepEqual(missingHeaders(res), [], name);
  }
});

test("the 424 page CSP allows its inline style only by hash, and the hash matches", async () => {
  const res = (await failurePaths())["config incomplete"];
  const csp = res.headers.get("content-security-policy");
  const body = await res.text();
  const css = /<style>([^<]*)<\/style>/.exec(body)[1];
  const hash = "sha256-" + createHash("sha256").update(css).digest("base64");
  assert.ok(csp.includes("style-src '" + hash + "'"), csp);
});

test("the header guard bites: a bare response and a page without a CSP are flagged", () => {
  assert.ok(missingHeaders(new Response("x", { status: 400 })).length >= 3);
  const page = new Response("<p>x</p>", {
    headers: { "content-type": "text/html; charset=utf-8", "x-content-type-options": "nosniff", "referrer-policy": "same-origin", "cache-control": "no-store" },
  });
  assert.ok(missingHeaders(page).some((m) => m.startsWith("csp:")));
});
