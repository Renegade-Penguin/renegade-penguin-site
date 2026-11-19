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

// Header-bound values never carry CR or LF.
function oneLine(value) {
  return String(value).replace(/[\r\n]+/g, " ").trim();
}

export async function sendContactMail(env, message) {
  if (!env || !env.EMAIL || typeof env.EMAIL.send !== "function") {
    throw new Error("mail binding EMAIL is not configured");
  }
  if (!env.MAIL_FROM) {
    throw new Error("MAIL_FROM is not configured");
  }
  await env.EMAIL.send({
    from: oneLine(env.MAIL_FROM),
    to: oneLine(env.MAIL_TO || DEFAULT_TO),
    subject: oneLine(message.subject),
    text: String(message.text),
    replyTo: oneLine(message.replyTo),
  });
}
