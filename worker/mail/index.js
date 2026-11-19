// Mail Worker for the contact form. Reached only by a service binding from the Pages Function
// (functions/api/_mail.js); it has no public address (see wrangler.jsonc). It owns the send_email
// binding because Pages Functions do not list send_email as a supported binding.
//
// Request:  POST, JSON { subject, text, replyTo }.
// Response: 200 sent, 400 bad request, 405 wrong method, 502 send failed. Bodies are fixed
//           short strings; request content and error details are never echoed or logged.
//
// Environment:
//   EMAIL       send_email binding pinned to RECIPIENT (see wrangler.jsonc)
//   MAIL_FROM   sender address on an onboarded domain; the only source of "from"

export const RECIPIENT = "contact@renegadepenguinllc.com";

export const LIMITS = { subject: 200, replyTo: 200, text: 20000 };

// A header-bound value never carries: a C0 or C1 control, DEL, U+00AD (soft hyphen), U+2028,
// U+2029, the bidi embeddings and overrides U+202A to U+202E, the bidi isolates U+2066 to U+2069,
// U+FEFF, or a lone surrogate. U+200E, U+200F and ordinary non-ASCII letters are allowed.
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
    if (request.method !== "POST") {
      const res = reply(405, "method not allowed");
      res.headers.set("allow", "POST");
      return res;
    }
    let data;
    try {
      const raw = await request.text();
      if (raw.length > 3 * (LIMITS.text + LIMITS.subject + LIMITS.replyTo)) return BAD();
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
