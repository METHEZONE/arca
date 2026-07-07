import type { MetadataRoute } from "next";

const BASE = "https://arca-the-zone-bio.vercel.app";

export default function sitemap(): MetadataRoute.Sitemap {
  return ["/", "/arca", "/arcaos", "/arcaconnect", "/arcademo"].map((path) => ({
    url: `${BASE}${path}`,
    changeFrequency: "weekly",
    priority: path === "/arca" ? 1 : 0.7,
  }));
}
