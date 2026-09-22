// Conservative classification: an unknown native/library/programming failure is
// unavailable, never a claim that the user's image is corrupt. Version-pinned
// libjpeg diagnostics are the only decoder exceptions we classify as bad input.
export function isInvalidJPEGError(error: unknown): boolean {
  if (!(error instanceof Error) || error.name !== 'Error') return false;
  const lines = error.message.split(/\r?\n/).filter(Boolean);
  return lines.length > 0 && lines.every((line) =>
    /^VipsJpeg: (?:Corrupt JPEG data:|Invalid JPEG file structure:|Premature end of JPEG file)/.test(line));
}
