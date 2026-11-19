// POST /api/contact: the contact form handler (Cloudflare Pages Function, same origin).
//
// Order of work: method, body size, honeypot, field validation, Turnstile siteverify, mail.
// Mail goes through ./_mail.js only. Required environment is listed in functions/README.md.
// Nothing here logs form content, the token or the secret.
import { sendContactMail } from "./_mail.js";

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

function text(status, message, extra = {}) {
  return new Response(message, {
    status,
    headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store", ...extra },
  });
}

function thanks() {
  return new Response(null, { status: 303, headers: { location: THANKS, "cache-control": "no-store" } });
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

// Single-line fields never carry CR or LF (they end up in the subject and Reply-To).
function line(value) {
  return String(value ?? "").replace(/[\r\n]+/g, " ").trim();
}

function validate(form) {
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
  // The email is checked on the raw value too, so a CR or LF inside it is an error, not a repair.
  const rawEmail = String(form.get("email") ?? "").trim();
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
    return text(500, "The form is not available right now.");
  }
  const token = String(form.get("cf-turnstile-response") ?? "");
  if (!token || token.length > MAX_TOKEN) return text(400, "Please complete the spam check and try again.");
  let human;
  try {
    human = await verifyTurnstile(token, env, request, doFetch);
  } catch {
    return text(502, "The spam check could not be reached. Please try again.");
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
    return text(502, "Your message could not be sent. Please email contact@renegadepenguinllc.com instead.");
  }
  return thanks();
}

export async function onRequest(context) {
  return handleContact(context.request, context.env);
}
