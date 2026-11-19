// Mail adapter for the contact form. The only module that touches the mail path.
//
// Design (issue #31): Pages Functions do not list send_email as a supported binding (Cloudflare
// docs read 2026-11-19), so this adapter calls a small separate Worker (worker/mail) through a
// service binding named MAIL_WORKER. That Worker owns the send_email binding, pins the recipient
// and takes the sender from its own MAIL_FROM. UNVERIFIED until staging (issue #5): nothing is
// deployed yet, so the service binding and the Worker send have not run against Cloudflare.
// contact.js and its tests do not change.
//
// Environment (Pages project):
//   MAIL_WORKER  service binding to renegade-penguin-mail (an object with an async fetch(request))
//   MAIL_SHARED_SECRET  encrypted secret, sent as header x-mail-auth; must equal the Worker's value
//   MAIL_FROM    sender address; checked here, and the Worker uses its own MAIL_FROM, not this one
//   MAIL_TO      recipient, checked here; the Worker ignores it and sends to its pinned address
//                (default contact@renegadepenguinllc.com)

export const DEFAULT_TO = "contact@renegadepenguinllc.com";

// A header-bound value never carries: a C0 or C1 control, DEL, U+00AD (soft hyphen), U+061C,
// U+200E, U+200F, U+2028, U+2029, the bidi embeddings and overrides U+202A to U+202E, the bidi
// isolates U+2066 to U+2069, U+FEFF, or a lone surrogate. That is every Unicode bidi formatting
// character. Ordinary non-ASCII letters (including right-to-left scripts) are allowed.
// Values are rejected, never repaired. contact.js uses the same test on visitor input.
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

// Throws without echoing the value (it may be personal data).
function headerValue(name, value) {
  if (hasControlChars(value)) throw new Error("invalid header value " + name);
  return String(value).trim();
}

export async function sendContactMail(env, message) {
  if (!env || !env.MAIL_WORKER || typeof env.MAIL_WORKER.fetch !== "function") {
    throw new Error("mail binding MAIL_WORKER is not configured");
  }
  if (!env.MAIL_SHARED_SECRET) {
    throw new Error("MAIL_SHARED_SECRET is not configured");
  }
  if (!env.MAIL_FROM) {
    throw new Error("MAIL_FROM is not configured");
  }
  headerValue("from", env.MAIL_FROM);
  headerValue("to", env.MAIL_TO || DEFAULT_TO);
  const body = JSON.stringify({
    subject: headerValue("subject", message.subject),
    text: String(message.text),
    replyTo: headerValue("replyTo", message.replyTo),
  });
  // The URL is a placeholder: a service binding ignores the host.
  const res = await env.MAIL_WORKER.fetch(
    new Request("https://mail.invalid/", {
      method: "POST",
      headers: { "content-type": "application/json", "x-mail-auth": String(env.MAIL_SHARED_SECRET) },
      body,
    }),
  );
  if (!res.ok) throw new Error("mail worker returned status " + res.status);
}
