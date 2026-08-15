// Resolve hook: retry extensionless relative specifiers with ".js" appended,
// so `import { DataStore } from "./data_store"` (bundler style) works under
// plain `node --test`.
export async function resolve(specifier, context, nextResolve) {
  try {
    return await nextResolve(specifier, context);
  } catch (err) {
    if (
      err &&
      err.code === "ERR_MODULE_NOT_FOUND" &&
      (specifier.startsWith("./") || specifier.startsWith("../")) &&
      !specifier.endsWith(".js") &&
      !specifier.endsWith(".mjs") &&
      !specifier.endsWith(".cjs")
    ) {
      return nextResolve(`${specifier}.js`, context);
    }
    throw err;
  }
}
