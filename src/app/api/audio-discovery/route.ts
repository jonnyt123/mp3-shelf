import { NextRequest, NextResponse } from "next/server";
import { discoveryQuery, normalizeOpenverseAudio } from "@/lib/open-audio";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Metadata-only proxy to an approved public catalog. Does not fetch arbitrary
 * user URLs or relay media; download requests remain subject to browser CORS.
 */
export async function GET(request: NextRequest) {
  let query: string;
  try { query = discoveryQuery(request.nextUrl.searchParams.get("q")); }
  catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Invalid search." },
      { status: 400, headers: { "Cache-Control": "no-store" } });
  }

  const apiURL = new URL("https://api.openverse.org/v1/audio/");
  apiURL.searchParams.set("q", query);
  apiURL.searchParams.set("page_size", "12");
  apiURL.searchParams.set("page", "1");
  apiURL.searchParams.set("license", "cc0,pdm,by,by-sa");
  apiURL.searchParams.set("mature", "false");
  try {
    const response = await fetch(apiURL, {
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(9000),
      next: { revalidate: 300 }
    });
    if (response.status === 429)
      return NextResponse.json({ error: "The open music catalog is rate-limited. Try again later." },
        { status: 429, headers: { "Cache-Control": "no-store" } });
    if (!response.ok)
      throw new Error(`Catalog returned HTTP ${response.status}`);
    const raw: unknown = await response.json();
    return NextResponse.json(
      { source: "Openverse", results: normalizeOpenverseAudio(raw) },
      { headers: { "Cache-Control": "public, max-age=60, s-maxage=300" } }
    );
  } catch {
    return NextResponse.json(
      { error: "The open music catalog is temporarily unavailable. Try again later." },
      { status: 502, headers: { "Cache-Control": "no-store" } }
    );
  }
}
