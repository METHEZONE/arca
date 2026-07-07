// Min's public profile served by the ARCA Ring page + vCard endpoint.
// This ships to visitors' phones by design — only put public-facing info here.

export const RING_OWNER = {
  fullName: "Minsung Park",
  koreanName: "박민성",
  title: "Founder, THE ZONE BIO — Building ARCA",
  org: "THE ZONE BIO",
  email: "me@thezonebio.com",
  phone: "+82 10-9942-7360",
  instagram: "minthezone",
  linkedin: "minsungparkzone",
  x: "methezone",
} as const;

export const RING_DEFAULT_CATEGORY = "26 BZCF Fellow";

/** vCard for Min. `meta` stamps when/where we connected into the NOTE so the
 *  saved contact carries the memory ("We connected via ARCA Ring — …"). */
export function ownerVCard(meta?: { at?: string; place?: string }): string {
  const o = RING_OWNER;
  const when = meta?.at
    ? new Date(meta.at).toLocaleString("ko-KR", {
        timeZone: "Asia/Seoul",
        year: "numeric",
        month: "short",
        day: "numeric",
        hour: "2-digit",
        minute: "2-digit",
      })
    : undefined;
  const note = [
    "We connected via ARCA Ring",
    when ? `— ${when}` : undefined,
    meta?.place ? `· ${meta.place}` : undefined,
  ]
    .filter(Boolean)
    .join(" ");

  return [
    "BEGIN:VCARD",
    "VERSION:3.0",
    "N:Park;Minsung;;;",
    `FN:${o.fullName}`,
    `ORG:${o.org}`,
    "TITLE:Founder — ARCA",
    `TEL;TYPE=CELL:${o.phone.replace(/\s/g, "")}`,
    `EMAIL;TYPE=INTERNET:${o.email}`,
    `URL:https://instagram.com/${o.instagram}`,
    `X-SOCIALPROFILE;TYPE=linkedin:https://www.linkedin.com/in/${o.linkedin}`,
    `X-SOCIALPROFILE;TYPE=twitter:https://x.com/${o.x}`,
    `NOTE:${note.replace(/[,;]/g, "\\$&")}`,
    "END:VCARD",
  ].join("\r\n");
}
