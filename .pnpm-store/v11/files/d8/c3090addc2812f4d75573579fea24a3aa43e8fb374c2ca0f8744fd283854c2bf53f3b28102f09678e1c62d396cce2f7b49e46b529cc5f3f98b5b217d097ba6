/// <reference types="vitest" />
import path from "path";
import { defineConfig } from "vite";
import dts from "vite-plugin-dts";
import packageJson from "./package.json";
import { glob } from "glob";

const getPackageName = () => {
  return packageJson.name;
};

const getPackageNameCamelCase = () => {
  try {
    return getPackageName().replace(/-./g, char => char[1].toUpperCase());
  } catch {
    throw new Error("Name property in package.json is missing.");
  }
};

export default defineConfig({
  base: "./",
  plugins: [
    dts(),
  ],
  build: {
    lib: {
      entry: {
        "aruco-marker": path.resolve(__dirname, "src/aruco-marker.ts"),
        element: path.resolve(__dirname, "src/element.ts"),
        ...Object.fromEntries((await glob(path.resolve(__dirname, "src/dictionaries/*.ts"))).map(file => ["dictionaries/" + path.basename(file, ".ts"), file])),
      },
      name: getPackageNameCamelCase(),
    },
    sourcemap: true,
  },
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "src"),
    },
  },
});
