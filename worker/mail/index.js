// Mail Worker for the contact form. Reached only by a service binding from the Pages Function
// (functions/api/_mail.js); it has no public address (see wrangler.jsonc). It owns the send_email
// binding because Pages Functions do not list send_email as a supported binding.
//
// Request:  POST, application/json { subject, text, replyTo }, header x-mail-auth.
// Response: 200 sent, 400 bad request, 401 unauthorized, 405 wrong method, 413 too large,
//           415 wrong content type, 502 send failed. Bodies are fixed short strings; request
//           content and error details are never echoed or logged.
//
// Environment:
//   MAIL_SHARED_SECRET  encrypted secret; x-mail-auth must equal it. Unset or empty: every
//                       request gets 401. Checked before the body is read.
//   EMAIL       send_email binding pinned to RECIPIENT (see wrangler.jsonc)
//   MAIL_FROM   sender address on an onboarded domain; the only source of "from"

export const RECIPIENT = "contact@renegadepenguinllc.com";

export const LIMITS = { subject: 200, replyTo: 200, text: 20000 };

// A header-bound value never carries: a C0 or C1 control, DEL, U+00AD (soft hyphen), U+061C,
// U+200E, U+200F, U+2028, U+2029, the bidi embeddings and overrides U+202A to U+202E, the bidi
// isolates U+2066 to U+2069, U+FEFF, or a lone surrogate. That is every Unicode bidi formatting
// character. Ordinary non-ASCII letters (including right-to-left scripts) are allowed.
// Values are rejected, never repaired. contact.js uses the same test on visitor input.
// KEEP IDENTICAL to hasControlChars in functions/api/_mail.js: worker/mail/test/mail.test.js
// fails if the two copies diverge.
export function hasControlChars(value) {
  for (const ch of String(value)) {
    const c = ch.codePointAt(0);
    if (
      c <= 0x1f ||
      (c >= 0x7f && c <= 0x9f) ||
      c === 0xad ||
      c === 0x61c ||
      c === 0x200e ||
      c === 0x200f ||
      c === 0x2028 ||
      c === 0x2029 ||
      (c >= 0x202a && c <= 0x202e) ||
      (c >= 0x2066 && c <= 0x2069) ||
      c === 0xfeff ||
      (c >= 0xd800 && c <= 0xdfff) // for...of yields a lone surrogate as its own character
    ) {
      return true;
    }
  }
  return false;
}

// One address, no spaces, angle brackets, commas, semicolons, quotes or parentheses.
const EMAIL_SHAPE = /^[^\s@<>,;:"()[\]\\]+@[^\s@<>,;:"()[\]\\]+\.[^\s@<>,;:"()[\]\\]+$/;

function reply(status, body) {
  return new Response(body, { status, headers: { "content-type": "text/plain; charset=utf-8" } });
}

const BAD = () => reply(400, "bad request");

// Application limit on the request body, in bytes (JSON escaping and multibyte text included).
const MAX_BODY_BYTES = 3 * (LIMITS.text + LIMITS.subject + LIMITS.replyTo);

// Constant-time comparison of two strings: hashes both to a fixed length, then XORs every byte.
async function safeEqual(a, b) {
  const enc = new TextEncoder();
  const [ha, hb] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  const x = new Uint8Array(ha);
  const y = new Uint8Array(hb);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

async function authorized(request, env) {
  const secret = env && env.MAIL_SHARED_SECRET;
  if (typeof secret !== "string" || secret.length === 0) return false;
  const given = request.headers.get("x-mail-auth");
  if (typeof given !== "string") return false;
  return safeEqual(given, secret);
}

// Reads the body incrementally and stops at max bytes (null). An oversized Content-Length is
// refused before any read; a missing or wrong one does not matter, the count is what is enforced.
async function readBounded(request, max) {
  const declared = request.headers.get("content-length");
  if (declared !== null && Number(declared) > max) return null;
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const all = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) {
    all.set(c, off);
    off += c.byteLength;
  }
  return new TextDecoder("utf-8", { fatal: true }).decode(all);
}

function validate(data) {
  if (!data || typeof data !== "object" || Array.isArray(data)) return null;
  const { subject, text, replyTo } = data;
  for (const [v, max] of [
    [subject, LIMITS.subject],
    [text, LIMITS.text],
    [replyTo, LIMITS.replyTo],
  ]) {
    if (typeof v !== "string" || v.length === 0 || v.length > max) return null;
  }
  if (hasControlChars(subject) || hasControlChars(replyTo)) return null;
  if (!EMAIL_SHAPE.test(replyTo)) return null;
  return { subject: subject.trim(), text, replyTo: replyTo.trim() };
}

export default {
  async fetch(request, env) {
    // Auth first, before the method or the body is looked at. Unset or empty secret: closed.
    if (!(await authorized(request, env))) return reply(401, "unauthorized");
    if (request.method !== "POST") {
      const res = reply(405, "method not allowed");
      res.headers.set("allow", "POST");
      return res;
    }
    const ct = (request.headers.get("content-type") || "").split(";")[0].trim().toLowerCase();
    if (ct !== "application/json") return reply(415, "unsupported media type");
    let data;
    try {
      const raw = await readBounded(request, MAX_BODY_BYTES);
      if (raw === null) return reply(413, "payload too large");
      data = JSON.parse(raw);
    } catch {
      return BAD();
    }
    const msg = validate(data);
    if (!msg) return BAD();
    try {
      if (!env || !env.EMAIL || typeof env.EMAIL.send !== "function") throw new Error("no binding");
      if (!env.MAIL_FROM || hasControlChars(env.MAIL_FROM)) throw new Error("no sender");
      await env.EMAIL.send({
        from: String(env.MAIL_FROM).trim(),
        to: RECIPIENT,
        subject: msg.subject,
        text: msg.text,
        replyTo: msg.replyTo,
      });
    } catch {
      return reply(502, "send failed");
    }
    return reply(200, "ok");
  },
};
