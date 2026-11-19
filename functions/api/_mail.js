// Mail adapter for the contact form. The only module that touches the platform mail binding.
//
// UNVERIFIED (issue #5): the exact Cloudflare Email Service binding call is not confirmed to
// work from a Pages Function. The send_email binding is not listed in the Pages Functions
// binding docs read on 2026-11-19, and the message field names used below (to, from, subject,
// text, replyTo) follow the Workers send_email documentation. Confirm both in staging. If the
// binding is not available in Pages, change only this file (service binding to a small Worker,
// or the Email Service REST API); contact.js and its tests do not change.
//
// Environment:
//   EMAIL       the mail binding (an object with an async send(message) method)
//   MAIL_FROM   sender address on an onboarded domain (required)
//   MAIL_TO     recipient, pinned here and never taken from the form
//               (default contact@renegadepenguinllc.com)

export const DEFAULT_TO = "contact@renegadepenguinllc.com";

// A header-bound value never carries: a C0 or C1 control, DEL, U+00AD (soft hyphen), U+2028,
// U+2029, the bidi embeddings and overrides U+202A to U+202E, the bidi isolates U+2066 to U+2069,
// U+FEFF, or a lone surrogate. U+200E, U+200F and ordinary non-ASCII letters are allowed.
// Values are rejected, never repaired. contact.js uses the same test on visitor input.
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

// Throws without echoing the value (it may be personal data).
function headerValue(name, value) {
  if (hasControlChars(value)) throw new Error("invalid header value " + name);
  return String(value).trim();
}

export async function sendContactMail(env, message) {
  if (!env || !env.EMAIL || typeof env.EMAIL.send !== "function") {
    throw new Error("mail binding EMAIL is not configured");
  }
  if (!env.MAIL_FROM) {
    throw new Error("MAIL_FROM is not configured");
  }
  await env.EMAIL.send({
    from: headerValue("from", env.MAIL_FROM),
    to: headerValue("to", env.MAIL_TO || DEFAULT_TO),
    subject: headerValue("subject", message.subject),
    text: String(message.text),
    replyTo: headerValue("replyTo", message.replyTo),
  });
}
