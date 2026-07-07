import { ImageResponse } from "next/og";

export const alt = "ARCA — It remembers everything. So you don't have to.";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default function Image() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          background:
            "radial-gradient(circle at 80% 10%, rgba(220,80,0,0.35), transparent 40%), radial-gradient(circle at 15% 90%, rgba(255,122,26,0.25), transparent 45%), #050302",
          color: "#ffedd7",
          fontFamily: "sans-serif",
        }}
      >
        {/* Spirit */}
        <div
          style={{
            width: 150,
            height: 150,
            borderRadius: 9999,
            background: "radial-gradient(circle at 36% 30%, #ff9d6b, #f75b2b 55%, #e2331a)",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            gap: 22,
            marginBottom: 48,
            boxShadow: "0 0 120px rgba(247,91,43,0.45)",
          }}
        >
          <div
            style={{
              width: 26,
              height: 34,
              background: "#fff6ec",
              borderRadius: "13px 13px 4px 4px",
            }}
          />
          <div
            style={{
              width: 26,
              height: 34,
              background: "#fff6ec",
              borderRadius: "13px 13px 4px 4px",
            }}
          />
        </div>

        <div style={{ display: "flex", fontSize: 76, fontWeight: 700, letterSpacing: -2 }}>
          It remembers everything.
        </div>
        <div
          style={{
            display: "flex",
            fontSize: 76,
            fontWeight: 700,
            letterSpacing: -2,
            color: "#ff7a1a",
          }}
        >
          So you don&apos;t have to.
        </div>

        <div
          style={{
            display: "flex",
            marginTop: 54,
            fontSize: 30,
            color: "rgba(255,237,215,0.65)",
          }}
        >
          ARCA — your second self · say “arca it” and walk away
        </div>
      </div>
    ),
    { ...size },
  );
}
