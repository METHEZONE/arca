import { defineConfig, globalIgnores } from "eslint/config";
import next from "eslint-config-next";
import react from "eslint-plugin-react";
import reactHooks from "eslint-plugin-react-hooks";

export default defineConfig([
  ...next,
  {
    plugins: { react, "react-hooks": reactHooks },
    rules: {
      // Stylistic: raw apostrophes/quotes in JSX copy are fine.
      "react/no-unescaped-entities": "off",
      // Intentional patterns (hydration-safe mount state, render-stable ids)
      // that the compiler-era hook rules flag — keep visible, not blocking.
      "react-hooks/set-state-in-effect": "warn",
      "react-hooks/refs": "warn",
    },
  },
  globalIgnores([
    ".next/**",
    "node_modules/**",
    "apps/**",
    "deck/**",
    "examples/**",
    "external/**",
    "hardware/**",
    "ir/**",
    "tmp/**",
  ]),
]);
