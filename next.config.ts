import type { NextConfig } from "next";

// /arcaconnect is also served through thezonebio.com via a beforeFiles rewrite
// (multi-zone). assetPrefix makes /_next assets load from this app's own
// origin when the HTML is delivered from thezonebio.com.
const PROD_ORIGIN = "https://arca-the-zone-bio.vercel.app";

const nextConfig: NextConfig = {
  assetPrefix: process.env.VERCEL_ENV === "production" ? PROD_ORIGIN : undefined,
  experimental: {
    serverActions: {
      bodySizeLimit: "100mb"
    }
  },
  async redirects() {
    return [{ source: "/ring", destination: "/arcaconnect", permanent: false }];
  }
};

export default nextConfig;
