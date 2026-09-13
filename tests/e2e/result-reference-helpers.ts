// Keep upstream payload assertions compatible with the fork's JSON reference
// annotation. Validate the metadata rather than dropping arbitrary first lines.
export function toolResultPayload(output: string): string {
  const prefix = "FX result reference: ";
  if (!output.startsWith(prefix)) return output;
  const boundary = output.indexOf("\n");
  if (boundary < 0) throw new Error("Missing referenced tool payload");
  const reference = JSON.parse(output.slice(prefix.length, boundary));
  if (
    !reference || Array.isArray(reference) ||
    Object.keys(reference).length !== 1 ||
    typeof reference.result_ref !== "string" || reference.result_ref.length === 0
  ) {
    throw new Error("Invalid FX result reference metadata");
  }
  return output.slice(boundary + 1);
}
