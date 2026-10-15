import { StateEffect, StateField } from '@codemirror/state';

export const placeImage = StateEffect.define<{ id: string; at: number } | null>();
/** A command's insertion point follows intervening edits while capture/attachment IO is pending. */
export const imageInsertion = StateField.define<{ id: string; at: number } | null>({
  create: () => null,
  update(value, tr) {
    if (value) value = { ...value, at: tr.changes.mapPos(value.at, 1) };
    for (const effect of tr.effects) if (effect.is(placeImage)) value = effect.value;
    return value;
  },
});

export function imageBytes(value: unknown): { filename: string; data: ArrayBuffer } {
  const v = value as { filename?: unknown; png?: unknown };
  if (typeof v?.filename !== 'string' || !/^[\w .-]+\.png$/.test(v.filename)
      || typeof v.png !== 'string' || v.png.length > 28 * 1024 * 1024) throw new Error('Invalid screen image');
  const bytes = Uint8Array.from(atob(v.png), c => c.charCodeAt(0));
  if (bytes.length < 8 || ![137,80,78,71,13,10,26,10].every((v,i) => bytes[i] === v)) throw new Error('Invalid PNG');
  return { filename: v.filename, data: bytes.buffer };
}
