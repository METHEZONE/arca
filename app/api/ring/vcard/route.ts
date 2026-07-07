export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { ownerVCard } from "@/lib/ring/profile";

// Served with a vCard MIME type so iOS/Android open the native
// "add to contacts" sheet. ?at=<ISO>&place=<label> stamps the meeting
// into the contact's NOTE field.
export async function GET(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const at = url.searchParams.get("at")?.slice(0, 40) || undefined;
  const place = url.searchParams.get("place")?.slice(0, 120) || undefined;

  return new Response(ownerVCard({ at, place }), {
    headers: {
      "Content-Type": "text/vcard; charset=utf-8",
      "Content-Disposition": 'attachment; filename="minsung-park.vcf"',
    },
  });
}
