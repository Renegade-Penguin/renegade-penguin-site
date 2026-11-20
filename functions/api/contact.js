// POST /api/contact: the contact form handler (Cloudflare Pages Function, same origin).
//
// Order of work: method, body size, honeypot, field validation, Turnstile siteverify, mail.
// Mail goes through ./_mail.js only. Required environment is listed in functions/README.md.
// Nothing here logs form content, the token or the secret.
import { sendContactMail, hasControlChars } from "./_mail.js";

const MAX_BODY_BYTES = 20000;
const THANKS = "/contact/thanks/";
const SITEVERIFY = "https://challenges.cloudflare.com/turnstile/v0/siteverify";
const TURNSTILE_ACTION = "contact";
const MAX_TOKEN = 2048;

// Values must match the option values in layouts/contact/list.html.
const SIZES = new Set(["1-10", "11-50", "51-250", "251-1000", "1001-plus"]);
const BUDGETS = new Set(["smaller-retainer", "standard-retainer", "one-off-project", "not-sure"]);
const TIMELINES = new Set(["urgent", "1-2-months", "3-6-months", "no-date"]);

const EMAIL_SHAPE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// The static _headers file does not apply to Pages Function responses, so every response built here
// goes through reply(), the one place that sets the header set. Nothing returns a bare Response.
const STYLE_HASH = "sha256-lhWzZNzDu0ylXnjClhIFyIt6ZCDTRFIluNuiFyylikw=";
// An HTML response loads nothing: no script, no image, no font, no frame. Its one inline style is
// allowed by hash, never by 'unsafe-inline'.
const HTML_CSP =
  "default-src 'none'; style-src '" + STYLE_HASH + "'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

function reply(body, status, extra = {}) {
  const headers = new Headers({
    "x-content-type-options": "nosniff",
    "referrer-policy": "same-origin",
    "cache-control": "no-store",
  });
  for (const [k, v] of Object.entries(extra)) headers.set(k, v);
  if ((headers.get("content-type") ?? "").startsWith("text/html")) {
    headers.set("content-security-policy", HTML_CSP);
  }
  return new Response(body, { status, headers });
}

function text(status, message, extra = {}) {
  return reply(message, status, { "content-type": "text/plain; charset=utf-8", ...extra });
}

// Cloudflare replaces any 5xx response with its own error page, so the visitor would never see
// the fallback address. Failures that are ours answer 424 with a small self-contained page.
// Nothing from the request is echoed.
const FALLBACK_EMAIL = "contact@renegadepenguinllc.com";
const FAILURE_PAGE =
  '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
  '<meta name="viewport" content="width=device-width, initial-scale=1">' +
  "<title>Message not sent</title>" +
  "<style>body{background:#0F0F0F;color:#F0F0F0;font-family:system-ui,sans-serif;line-height:1.6;" +
  "max-width:36rem;margin:3rem auto;padding:0 1rem}a{color:#FBB03B}</style></head><body><main>" +
  "<h1>We could not send your message</h1>" +
  "<p>Sorry, something went wrong on our side and your message did not go through.</p>" +
  // email_off markers: Cloudflare Email Address Obfuscation would otherwise rewrite this address.
  '<p>Please email us directly at <!--email_off--><a href="mailto:' + FALLBACK_EMAIL + '">' + FALLBACK_EMAIL + "</a><!--/email_off-->.</p>" +
  '<p><a href="/contact/">Go back to the contact form</a></p></main></body></html>';

function failurePage() {
  return reply(FAILURE_PAGE, 424, { "content-type": "text/html; charset=utf-8" });
}

function thanks() {
  return reply(null, 303, { location: THANKS });
}

// Read the body as text, giving up as soon as it passes the limit.
async function readLimited(request) {
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) return null;
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_BODY_BYTES) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const all = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) {
    all.set(c, at);
    at += c.byteLength;
  }
  return new TextDecoder().decode(all);
}

// Single-line fields feed the subject and Reply-To. They are checked raw (before trimming) and a
// control character is an error, never repaired. Only the free-text need may hold line breaks.
const SINGLE_LINE_FIELDS = ["name", "email", "organization", "size", "budget", "timeline", "heard", "consent"];

function line(value) {
  return String(value ?? "").trim();
}

function validate(form) {
  for (const f of SINGLE_LINE_FIELDS) {
    if (hasControlChars(form.get(f) ?? "")) return "Please remove control characters from the form fields.";
  }
  const v = {
    name: line(form.get("name")),
    email: line(form.get("email")),
    organization: line(form.get("organization")),
    size: line(form.get("size")),
    need: String(form.get("need") ?? "").trim(),
    budget: line(form.get("budget")),
    timeline: line(form.get("timeline")),
    heard: line(form.get("heard")),
    consent: line(form.get("consent")),
  };
  const rawEmail = v.email;
  if (!v.name || v.name.length > 100) return "Please enter your name (100 characters or fewer).";
  if (!rawEmail || rawEmail.length > 200 || !EMAIL_SHAPE.test(rawEmail)) return "Please enter a valid work email (200 characters or fewer).";
  if (!v.organization || v.organization.length > 200) return "Please enter your organization (200 characters or fewer).";
  if (!SIZES.has(v.size)) return "Please choose an organization size.";
  if (!v.need || v.need.length > 4000) return "Please describe what you need (4000 characters or fewer).";
  if (!BUDGETS.has(v.budget)) return "Please choose a budget band.";
  if (!TIMELINES.has(v.timeline)) return "Please choose a timeline.";
  if (v.heard.length > 200) return "How you heard about us must be 200 characters or fewer.";
  if (v.consent !== "yes") return "Please confirm you consent to being contacted.";
  return v;
}

async function verifyTurnstile(token, env, request, doFetch) {
  const body = new URLSearchParams({ secret: env.TURNSTILE_SECRET, response: token });
  const ip = request.headers.get("cf-connecting-ip");
  if (ip) body.set("remoteip", ip);
  const res = await doFetch(SITEVERIFY, { method: "POST", body });
  if (!res.ok) throw new Error("siteverify status " + res.status); // service trouble, not a failed token
  const out = await res.json();
  return out.success === true && out.hostname === env.EXPECTED_HOSTNAME && out.action === TURNSTILE_ACTION;
}

export async function handleContact(request, env, deps = {}) {
  const doFetch = deps.fetch ?? globalThis.fetch;
  const sendMail = deps.sendMail ?? sendContactMail;

  if (request.method !== "POST") return text(405, "Method not allowed.", { allow: "POST" });

  const raw = await readLimited(request);
  if (raw === null) return text(413, "The message is too large.");
  const form = new URLSearchParams(raw);

  // Honeypot: a bot that fills the hidden field is thanked and dropped.
  if (String(form.get("website") ?? "").trim() !== "") return thanks();

  const v = validate(form);
  if (typeof v === "string") return text(400, v);

  if (!env.TURNSTILE_SECRET || !env.EXPECTED_HOSTNAME) {
    console.error("contact: server configuration is incomplete");
    return failurePage();
  }
  const token = String(form.get("cf-turnstile-response") ?? "");
  if (!token || token.length > MAX_TOKEN) return text(400, "Please complete the spam check and try again.");
  let human;
  try {
    human = await verifyTurnstile(token, env, request, doFetch);
  } catch {
    return failurePage();
  }
  if (!human) return text(400, "The spam check failed. Please go back and try again.");

  const message = {
    subject: ("Contact form: " + v.name + " (" + v.organization + ")").slice(0, 200),
    replyTo: v.email,
    text: [
      "Name: " + v.name,
      "Email: " + v.email,
      "Organization: " + v.organization,
      "Size: " + v.size,
      "Budget: " + v.budget,
      "Timeline: " + v.timeline,
      "Heard about us: " + (v.heard || "(not given)"),
      "Consent to be contacted: yes",
      "",
      "What they need:",
      v.need,
      "",
    ].join("\n"),
  };
  try {
    await sendMail(env, message);
  } catch (err) {
    // Log the error class only: messages can echo the address or the body.
    console.error("contact: mail send failed (" + (err && err.name ? err.name : "Error") + ")");
    return failurePage();
  }
  return thanks();
}

export async function onRequest(context) {
  return handleContact(context.request, context.env);
}
